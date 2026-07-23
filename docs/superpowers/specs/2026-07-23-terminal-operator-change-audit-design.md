# Design Note — Log every terminal operator-ID change to the audit trail

**Date:** 2026-07-23
**Author:** Blue Ridge Automation
**Status:** Draft — design + implementation plan only (no code changed by this note)
**Requirement (verbatim):** *"Any terminal user id change needs to be logged."*

---

## 1. Intent

Shop-floor terminals attribute actions to an operator by **initials** (operators have no
AD account). When the active operator identity at a terminal **changes** — operator A hands
off to operator B — that transition must be recorded in the audit trail: **who was active,
who became active, at which terminal, when.** Today the handoff mutates session state
silently, leaving no durable record of who was signed in at a station across a shift.

---

## 2. Current state (resolved from code)

### 2.1 Where the operator identity lives

The active operator is carried on the Perspective **session**, not the DB:

- `session.custom.user` — `{appUserId, initials, displayName, ignitionRole}`
- `session.custom.appUserId` — the BIGINT `AppUser.Id` used for mutation attribution
  (read back by `BlueRidge.Common.Util._currentAppUserId()` →
  `system.perspective.getSessionInfo()["custom"]["appUserId"]`, dev-fallback `2`).

### 2.2 The single mutation point — `InitialsEntry.loginAs()`

`ignition/projects/MPP/.../views/BlueRidge/Components/Popups/InitialsEntry/view.json`,
custom method `loginAs(appUserId, initials, displayName, ignitionRole)`:

```python
self.session.custom.user = {"appUserId": appUserId, "initials": initials,
                            "displayName": displayName, "ignitionRole": ignitionRole}
self.session.custom.appUserId = appUserId
system.perspective.closePopup(self.view.params.popupId or "mpp-initials")
```

**`loginAs` is the ONE place the terminal operator id changes.** It is reached from every
entry path:
- `submitInitials()` — a recognised-initials sign-in (typed or scanned),
- `registerOperatorResult` handler — after a brand-new operator self-registers
  (`UnknownInitials` → `RegisterOperator`).

The **OperatorBar** component (`Components/PlantFloor/OperatorBar`) renders the current
operator and opens the InitialsEntry popup via its **Change Operator** button. It performs no
identity write itself — it only launches the popup.

**`Terminal.applyToSession` does NOT touch operator identity.** It binds terminal/printer/PLC/
closure context and *clears the cell*; the operator dict is untouched. So the operator-change
detection point is exclusively `loginAs`, not the terminal resolver. (Confirmed by reading
`BlueRidge.Location.Terminal.applyToSession`.)

### 2.3 Existing audit plumbing this reuses

- **`Audit.Audit_LogOperation`** (`R__Audit_Audit_LogOperation.sql`) — the plant-floor
  operation-audit writer. Routes `@LogEntityTypeCode = N'Lot'` (with a non-null EntityId) to
  the 20-yr `Lots.LotEventLog`; **everything else lands in the 7-yr `Audit.OperationLog`.**
  Emits **no result set** (safe to `EXEC` from inside another proc's transaction / INSERT-EXEC
  caller). Resolves code strings → ids internally.
- **`Audit.LogEntityType`** already has **`AppUser` (Id 16)** — no new entity type needed.
- **`Audit.ufn_MidDot()`** / **`Audit.ufn_TruncateActivity()`** — description helpers.
- Reference proc that models every convention we need (reject-before-transaction, resolved-name
  FK sub-objects, `SELECT @Status,@Message`, no OUTPUT params, failure logging):
  **`Oee.DowntimeEvent_UpdateReason`** (`R__Oee_DowntimeEvent_UpdateReason.sql`).

---

## 3. Design

### 3.1 Trigger point

Fire the audit write **inside `loginAs`**, capturing the OLD identity from
`self.session.custom.user` *before* overwriting it, and the NEW identity from the incoming
params. Because all sign-in paths funnel through `loginAs`, one call site covers typed sign-in,
scanned sign-in, and post-registration sign-in with no duplication.

Ordering inside `loginAs`:
1. read `old = self.session.custom.user` (may be empty on first bind),
2. write the new `session.custom.user` + `session.custom.appUserId` (unchanged),
3. call the thin entity wrapper `BlueRidge.Location.AppUser.logOperatorChange(...)`
   (fire-and-forget — a logging failure must never block the operator from signing in),
4. close the popup.

Per **"no business logic in Python"**, the Python does zero domain work: it passes old/new
`appUserId` + the terminal id to a **SQL proc** that resolves names, builds the description +
JSON, and writes the audit row.

### 3.2 What is captured

| Field | Source | Notes |
|---|---|---|
| Old operator | `session.custom.user.appUserId` (pre-write) | NULL on first bind of the session |
| New operator | `loginAs` param `appUserId` | never NULL on a successful sign-in |
| Terminal | `session.custom.terminal.terminalLocationId` | may be NULL on the fallback/unregistered terminal |
| Timestamp | `SYSUTCDATETIME()` inside `Audit_LogOperation` | stored UTC, displayed ET at read (convention) |
| Attribution (`UserId`) | the **NEW** operator's `AppUser.Id` | see §7 open question (1) |

### 3.3 Audit payload (SUBJECT · CATEGORY · ACTION + resolved-name FK sub-objects)

Routed through `Audit.Audit_LogOperation` with `@LogEntityTypeCode = N'AppUser'`,
`@EntityId = <new AppUserId>`, `@LogEventTypeCode = N'OperatorChanged'` → lands in
**`Audit.OperationLog`** (correct: an operator handoff is a general operational event, not LOT
genealogy, so it does not belong in the Honda 20-yr `LotEventLog`).

**Description** (via `ufn_MidDot()` + `ufn_TruncateActivity()`):
- Handoff: `<TerminalCode> · Operator · Changed <OldInitials> → <NewInitials>`
- First bind (no prior operator): `<TerminalCode> · Operator · Signed in <NewInitials>`
- Fallback terminal (no terminal code): substitute `Terminal` literal for `<TerminalCode>`.

**OldValue / NewValue JSON** — resolved-name `AppUser` sub-objects (NOT bare ids), mirroring
the convention (`{Id, Code, Name}` shape; for `AppUser` map `Code = Initials`,
`Name = DisplayName`):

```json
// OldValue (null wrapper when first bind)
{ "AppUser": { "Id": 42, "Code": "AB", "Name": "Alice Brown" } }
// NewValue
{ "AppUser": { "Id": 57, "Code": "CD", "Name": "Carol Dean" } }
```

### 3.4 New proc — `Audit.OperatorChange_Log`

A dedicated mutation proc (returns a `{Status, Message}` status row; NQ `type: "Query"`).
Signature:

```
Audit.OperatorChange_Log
    @OldAppUserId       BIGINT = NULL,   -- NULL on first bind
    @NewAppUserId       BIGINT,          -- required
    @TerminalLocationId BIGINT = NULL,   -- NULL on fallback terminal
    @AppUserId          BIGINT           -- attribution (= @NewAppUserId, see §7)
```

Behaviour (models `DowntimeEvent_UpdateReason`):
- **Guards before any transaction:** `@NewAppUserId` required; new operator must exist
  (`Location.AppUser`); `@OldAppUserId`, if supplied, resolvable — an unresolvable old id
  degrades to a `null` OldValue rather than rejecting (never block a valid sign-in). Rejections
  `SELECT @Status,@Message; RETURN;` with no open transaction.
- **No-op guard:** if `@OldAppUserId = @NewAppUserId` (re-scan of the same operator), return
  `Status=1, Message='No operator change'` **without** writing a row (avoids audit noise from
  re-authenticating the same person). *(See §7 open question (2) — this could be desirable to
  log as a presence re-confirm; recommend suppressing.)*
- Resolve `TerminalCode` from `Location.Location`; resolve both operators' `Initials`/
  `DisplayName`; build `@Description`, `@OldValue`, `@NewValue`.
- `BEGIN TRANSACTION` → `EXEC Audit.Audit_LogOperation ...` → `COMMIT`.
  (No base-table write of our own — the audit row *is* the mutation. The transaction wraps the
  single `Audit_LogOperation` call for CATCH/ROLLBACK symmetry.)
- **INSERT-EXEC safe:** `Audit_LogOperation` emits no result set, so this proc's single
  `SELECT @Status,@Message` is the only result set — callable/testable via INSERT-EXEC.
- CATCH → `Audit.Audit_LogFailure` (best-effort) + `RAISERROR` (not `THROW`).

Attribution note: because `Audit_LogOperation` stamps `UserId = @AppUserId`, and the incoming
operator is the actor who authenticated, pass `@AppUserId = @NewAppUserId`.

### 3.5 Migration — one new `LogEventType` seed

`Audit.LogEntityType` needs **nothing new** (`AppUser` = Id 16 exists).

`Audit.LogEventType` needs one new row, `OperatorChanged`. Current max seeded Id observed:
`DowntimeVoided = 74` (migration `0043`); `ClosureModeChanged` (0041) used a dynamic
`MAX(Id)+1`. **Proposed Id 75, code `OperatorChanged`**, guarded by the standard
`IF NOT EXISTS (... WHERE Id = 75 OR Code = N'OperatorChanged')` idempotent pattern.

> ⚠️ Verify the next-free id at build time — there is an apparent gap at Id 70 between
> `ClosureModeChanged` (0041, dynamic) and the `71–74` block (0043). Prefer the
> `MAX(Id)+1`-with-Code-guard approach (as 0041 did) if a hard-coded 75 risks collision on any
> environment where 0041 resolved to 70.

New versioned migration, e.g. `00NN_operator_change_audit_event.sql` (next free number at build
time), seeds only the `LogEventType` row + a `SchemaVersion` marker. The proc + NQ are
repeatable (`R__Audit_OperatorChange_Log.sql`, `location/...` or `audit/...` NQ).

### 3.6 Ignition changes (high level)

- **`R__Audit_OperatorChange_Log.sql`** — the proc (repeatable).
- **Core NQ** `audit/OperatorChange_Log` (or under `location/`) — `type: "Query"` (status-row
  proc), params `oldAppUserId, newAppUserId, terminalLocationId, appUserId`. NQ lives in
  **Core** (all NQs are Core per topology memory).
- **`BlueRidge.Location.AppUser.logOperatorChange(oldAppUserId, newAppUserId,
  terminalLocationId)`** — thin wrapper: coerce ids, default `appUserId = newAppUserId`, call
  `Common.Db.execMutation`, swallow errors (`except (Exception, java.lang.Exception)`) so a
  logging fault never blocks sign-in. *(AppUser is the natural home; the Audit script module is
  an acceptable alternative.)*
- **`InitialsEntry/loginAs`** — capture `old`, then after the identity write call
  `logOperatorChange(old.appUserId, appUserId, session.custom.terminal.terminalLocationId)`.
  This is an **edit to an existing view** → do it in **Designer** (view-edit boundary), or via a
  guarded file edit + `scan.ps1` if Designer is closed and the escape hazards are handled.

No other view changes — every sign-in path already funnels through `loginAs`.

---

## 4. Data flow (end to end)

```
OperatorBar [Change Operator]
   └─ InitialsEntry popup ─ submitInitials / registerOperatorResult
        └─ loginAs(appUserId, initials, ...)
             ├─ old = session.custom.user            (capture BEFORE)
             ├─ session.custom.user / appUserId = new (unchanged write)
             └─ AppUser.logOperatorChange(oldId, newId, terminalLocationId)   [fire-and-forget]
                  └─ NQ audit/OperatorChange_Log (type Query)
                       └─ Audit.OperatorChange_Log  (resolve names, build desc+JSON)
                            └─ Audit.Audit_LogOperation  (entity 'AppUser', event 'OperatorChanged')
                                 └─ INSERT Audit.OperationLog   (UTC ts; ET at read)
```

---

## 5. Phased TDD implementation plan

**Phase 1 — Migration + proc (SQL, TDD).**
1. Write `sql/tests/01_audit_infrastructure/0NN_OperatorChange_Log.sql` FIRST (INSERT-EXEC the
   status row; assert an `Audit.OperationLog` row exists with the right `LogEntityTypeId`
   (AppUser), `LogEventTypeId` (OperatorChanged), `EntityId = newId`, `UserId = newId`,
   resolved-name JSON in Old/New, and the `SUBJECT · CATEGORY · ACTION` description shape).
   Cover: (a) normal handoff, (b) first bind (`@OldAppUserId = NULL` → null OldValue,
   "Signed in" description), (c) same-operator no-op (no row written, `Status=1`),
   (d) unknown `@NewAppUserId` reject, (e) NULL terminal (fallback) → `Terminal` literal.
2. Add the versioned migration seeding `LogEventType` `OperatorChanged` (verify next-free Id).
3. Author `R__Audit_OperatorChange_Log.sql` until the suite is green.
4. Full SQL reset on a throwaway `MPP_MES_Test` (never Jacques's `MPP_MES_Dev`); confirm the new
   migration applies in sequence and the suite passes.

**Phase 2 — NQ + entity wrapper (Ignition backend).**
5. Add Core NQ `audit/OperatorChange_Log` (`type: "Query"`).
6. Add `AppUser.logOperatorChange(...)`; unit-exercise via script console against `MPP_MES_Dev`
   (assert a row lands; assert a bad id degrades quietly).
7. `.\scan.ps1`.

**Phase 3 — View wiring (Designer).**
8. Edit `InitialsEntry.loginAs` to capture old + call the wrapper (Designer edit of an existing
   view).
9. `.\scan.ps1`; live smoke: sign in operator A, then Change Operator → operator B; confirm one
   `OperatorChanged` row per handoff (old→new resolved names), one "Signed in" row on the first
   bind, and **no** row on a same-operator re-scan; confirm it appears in the Audit Browser with
   an ET timestamp.

**Phase 4 — Docs.** FDS note (attribution/audit section) + `PROJECT_STATUS.md` header; regen
docx if the FDS body changes.

---

## 6. Conventions honoured

- No OUTPUT params; every path ends `SELECT @Status,@Message` (FDS-11-011). NQ `type: "Query"`.
- All rejects run **before** `BEGIN TRANSACTION`; `RAISERROR` (not `THROW`) in CATCH.
- Description via `ufn_MidDot()` + `ufn_TruncateActivity()`; resolved-name FK sub-objects in
  Old/New JSON.
- Timestamps UTC-stored, ET-displayed at read.
- No business logic in Python — the wrapper is inert glue; name resolution + payload shaping are
  in SQL.
- NQ in Core (topology memory). Existing-view edit → Designer (view-edit boundary).
- Wrapper never throws (`except (Exception, java.lang.Exception)`) — sign-in must not depend on
  audit success.

---

## 7. Open questions (flagged for Jacques)

1. **Attribution identity.** Recommend `UserId` = the **new** operator (they authenticated /
   took the action; matches how `loginAs` immediately makes them current). Alternative: attribute
   to the outgoing operator (they "released" the station). The old + new are both captured in the
   payload regardless — this only decides the `UserId` column. **Recommend: new operator.**

2. **Fire on first bind of the session?** When a session's first operator signs in, there is no
   prior operator (`OldAppUserId = NULL`). **Recommend YES** — "who was active when" is exactly
   the value of this log, and the first sign-in is a real identity assumption at the terminal. The
   description degrades to "Signed in <initials>". (Easy to suppress later by rejecting NULL old
   if MPP disagrees.)

3. **Same-operator re-scan.** Recommend **suppress** (no row) to avoid audit noise when an
   operator re-enters their own initials. If MPP wants a presence "re-confirm" trail (e.g. proof
   of attendance across a long shift), flip the no-op guard to instead write an event — cheap to
   change, but off by default.

4. **Sign-out / idle timeout.** This note covers *change* (A→B) and *first bind*. It does **not**
   cover an explicit sign-out to "nobody", because no such affordance exists today (there is no
   path that sets `session.custom.user` back to empty). If a future idle-timeout / lock feature
   clears the operator, route that clear through the same wrapper (`newAppUserId = NULL` would
   need a proc tweak — currently `@NewAppUserId` is required). Out of scope until that feature
   exists.

5. **Event-type Id.** Confirm the next-free `Audit.LogEventType.Id` at build time (possible gap
   at 70; see §3.5). Prefer the guarded `MAX(Id)+1` pattern if a hard-coded 75 is not safe on all
   environments.
