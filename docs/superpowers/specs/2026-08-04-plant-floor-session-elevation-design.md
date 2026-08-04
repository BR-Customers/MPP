# Plant-floor session, identity & time-boxed elevation

**Date:** 2026-08-04
**Author:** Blue Ridge Automation
**Status:** Approved — ready for implementation plan
**Scope:** Plant-floor app (`MPP` project) only. Covers FAT items #6, #8, #9, #10, #11, #12 (and the #5 test aid). #7 (config-app standing gate) is noted as adjacent, out of this spec.

## Problem

Today the plant-floor terminal has an **operator-presence** identity (initials) and a
**per-action AD elevation** that re-prompts for credentials on every protected action
(`AppUser.elevate` docstring: *"No sticky session — every protected action re-prompts"*).
FAT surfaced a different operating model:

- A supervisor should elevate **once** and complete several protected tasks within a short
  window, then the terminal auto-reverts to the default operator prompt (#11).
- The shop-floor nav menu, the config-app launch, and tool config must be **locked behind
  elevation** (#9, #10, #12).
- Operator-presence and elevation **timeout durations** must be configurable (#8, #5), edited in
  the User Management view.
- Operator presence must also re-confirm on **die-cast cell/context change** (#6).
- AD supervisors need a **clean way to be linked to an `AppUser.Id`** so their (now identity-
  replacing) actions attribute correctly.

## Decisions (locked)

1. **Elevation = time-boxed elevated mode**, plant-floor only. One AD auth opens a rolling
   window; protected actions inside it proceed without re-prompting.
2. **Replaced identity** — while elevated, the supervisor **becomes** the session user
   (`session.custom.user` + `appUserId` → supervisor). All actions in the window attribute to the
   supervisor's `AppUser.Id`. On window end, the terminal returns to a cold operator-initials
   prompt (the prior operator is not restored — they re-enter initials).
3. **Elevation timeout = 5-min rolling idle** (configurable). Activity pushes the deadline;
   5 minutes of no activity ends the window.
4. **Operator-presence timeout = soft re-confirm** (existing `IdleReconfirmModal`: "Operate as
   BOB? Yes / change operator"), duration configurable. **Also fires on die-cast cell/context
   change (#6).** Not a hard sign-out.
5. **Timeout durations are global** (one value each), edited in the **User Management view**
   above the operator table.
6. **Access gating is primarily "elevate-then-reveal" (Style 1):** protected controls bind
   `enabled`/`visible` to `isElevated`; a single "Supervisor access" entry opens the elevation
   modal. A `requireElevation(...)` helper (Style 2) is the escape hatch for the few actions that
   must elevate-and-immediately-act with side-effect params (e.g. `MoveOverride`).
7. **AppUser is the single identity table.** A supervisor is a row with `AdAccount` +
   `IgnitionRole` set. No new identity tables — `AuthenticateAd` already maps AD → `AppUser.Id`.

## Identity model (unchanged data model, new UI)

`Location.AppUser`: Id, Initials, DisplayName, `AdAccount` (nullable), `IgnitionRole` (nullable).

- **Operator** rows: Initials + DisplayName; AD/role null. Created via shop-floor self-register.
- **Supervisor** rows: `AdAccount` + `IgnitionRole` set (Initials optional). `AppUser_AuthenticateAd`
  resolves `@AdAccount` → active `AppUser` row → `{AppUserId, IgnitionRole}` and audits
  `ElevationGranted`/`ElevationDenied`.

The **only gap is UI**: `AppUser_Create`/`AppUser_Update` already accept `adAccount` +
`ignitionRole`; the User Management editor must surface them cleanly so a supervisor's AD login
resolves to a real `AppUser.Id` (§F).

## New: global session policy (durations)

A single-row global settings table, read into every plant-floor session:

```
Location.SessionPolicy
  Id                             BIGINT IDENTITY PK   (single row, Id = 1)
  OperatorPresenceTimeoutSeconds INT NOT NULL         (default 180)
  ElevationTimeoutSeconds        INT NOT NULL         (default 300)
  UpdatedAt                      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
  UpdatedByUserId                BIGINT NOT NULL FK -> Location.AppUser(Id)
```

- `Location.SessionPolicy_Get` — returns the single row (both durations). No OUTPUT params.
- `Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds, @ElevationTimeoutSeconds,
  @AppUserId` — validates positive bounds (e.g. 30–3600 s), writes an audit ConfigLog row
  (`SessionPolicy` entity, `Updated`, field-diff Description), returns `Status, Message`.
- Seed the single row (Id 1, defaults 180/300) in a migration.
- Durations are **seconds** so #5's "1-minute" test is a value change, not a rebuild.

The values load into `session.custom.policy = {operatorPresenceTimeoutSeconds,
elevationTimeoutSeconds}` at session start (extend `Terminal.applyToSession` / the session
startup that already seeds `session.custom.terminal`).

## Session state (additions to `session.custom`)

- `elevatedUntil` — epoch-ms deadline; `null` when not elevated. `isElevated` ≝
  `elevatedUntil != null && elevatedUntil > now`.
- `policy` — `{operatorPresenceTimeoutSeconds, elevationTimeoutSeconds}` (from `SessionPolicy`).
- `pendingElevatedAction` — `{code, params}` stash for Style-2 async replay; cleared after replay.
- `user` / `appUserId` — existing; **swapped to the supervisor** on elevation, cleared on reset.

## Components & flows

### 1. Elevation entry + `elevationResult` handler (app shell)
A single **"Supervisor access"** control (header) opens the existing `ElevationModal`
(`actionCode="SupervisorAccess"`). The app shell owns ONE page-scoped `elevationResult` handler:

```
on elevationResult(payload):
    if not payload.success: return   # modal already showed the error
    # Replaced identity + open the rolling window
    session.custom.user        = { appUserId: payload.appUserId, displayName: payload.displayName,
                                    ignitionRole: payload.ignitionRole, initials: "" }
    session.custom.appUserId   = payload.appUserId
    session.custom.elevatedUntil = nowMs() + policy.elevationTimeoutSeconds*1000
    # Style-2 replay, if this elevation was triggered to run a specific action
    pending = session.custom.pendingElevatedAction
    if pending: dispatchElevatedAction(pending.code, pending.params)
    session.custom.pendingElevatedAction = None
```

`ElevationModal` and `AppUser.elevate`/`AuthenticateAd` are unchanged (still validate the AD
credential + audit `ElevationGranted`). What changes is that the **caller now persists elevated
state** instead of doing one action and forgetting.

### 2. Style 1 — elevate-then-reveal (the bulk: #9, #10, #12)
Protected controls bind to `isElevated`:
- **Nav menu (#10):** menu control `enabled` ← `isElevated`; disabled tooltip "Supervisor access
  required." Tapping "Supervisor access" unlocks it for the window.
- **Launch config app / tool config (#9/#12):** those buttons `enabled` ← `isElevated`; once
  elevated, tapping launches (the config app then enforces its own standing AD gate, §G).

No per-control async logic — controls simply light up while the window is open.

### 3. Style 2 — `requireElevation` (param-carrying actions: `MoveOverride`, future overrides)
`BlueRidge.Common.Session.requireElevation(actionCode, actionLabel, params)` (thin, in a view
script — it touches session + popups):

```
requireElevation(code, label, params):
    if isElevated():
        dispatchElevatedAction(code, params)          # already open → act now
    else:
        session.custom.pendingElevatedAction = {code, params}
        openPopup(ElevationModal, {actionCode: code, actionLabel: label, replyMessage: "elevationResult"})
```

`dispatchElevatedAction(code, params)` is a small explicit `code → handler` map (NOT `eval` — see
the anti-pattern in the conventions pack). `MoveOverride` migrates from "always open modal" to
`requireElevation("MoveOverride", "Move override", {…})`, so it no longer re-prompts inside an
open window.

### 4. Idle + presence watcher (app shell, always mounted)
A single always-mounted watcher (timer ticking ~10 s, or a binding on
`session.props.lastActivity`) evaluates the **active** deadline:

```
idleMs = nowMs() - session.props.lastActivity
if isElevated():
    if idleMs > policy.elevationTimeoutSeconds*1000:  endElevatedWindow()   # -> reset (§5)
else:  # operator presence
    if idleMs > policy.operatorPresenceTimeoutSeconds*1000: openIdleReconfirm()  # existing modal
```

Only one mode is active at a time (elevated → elevation timeout governs; operator → presence
timeout governs). The existing `IdleReconfirmModal` "change operator" path already clears
`user`/`appUserId` and opens `InitialsEntry`.

### 5. Reset Terminal button + elevation expiry (#11)
An always-visible header control, and the same routine the elevation-idle watcher calls:

```
resetTerminal():
    audit operator/elevation reset (logOperatorChange-style)
    session.custom.user          = {appUserId: None, displayName: "", ignitionRole: "", initials: ""}
    session.custom.appUserId     = None
    session.custom.elevatedUntil = None
    navigate(session.custom.terminal.defaultScreen)
    openPopup(InitialsEntry)
```

Consequence of the Replaced model (called out for the team): when an elevation window ends
(timeout or Reset), the terminal is operator-less and prompts fresh initials — the pre-elevation
operator re-signs in.

### 6. Die-cast cell/context change → presence re-confirm (#6)
When the die-cast screen's cell/context changes (the `session.custom.cell` / selected cell
changes), fire the operator-presence re-confirm (`IdleReconfirmModal`) — same modal as the idle
path, just a different trigger. Does not fire while elevated (a supervisor changing context is
expected).

## User Management view additions (config app — §F)
`MPP_Config` → `Views/Audit/Users`:
- **Above the operator table:** a global-policy panel with two numeric inputs (operator-presence
  timeout, elevation timeout, shown in seconds/minutes) bound to `SessionPolicy_Get`, saved via
  `SessionPolicy_Update`. Standard `notifyResult` feedback.
- **Per user:** expose `AdAccount` + `IgnitionRole` in the user editor (procs already accept
  them) so an AD supervisor maps to a real `AppUser.Id`. Make the link obvious (e.g. a badge/column
  showing "AD: domain\\user" vs "Operator only").

## Out of scope (noted)
- **#7 config-app standing AD gate** — a project/view permission on `MPP_Config` requiring an
  authenticated AD user at all times. Separate, small; not part of the plant-floor elevation model.
- **Attribution correctness dependency** — because elevation *replaces* identity, every protected/
  production proc call must receive `session.custom.appUserId` explicitly (the pattern already
  fixed for Trim OUT). The broken `_currentAppUserId()`/`getSessionInfo()` helper is being fixed
  under a separate task; this spec assumes views pass `session.custom.appUserId`, which then simply
  carries the supervisor's id while elevated.

## Error handling
- Elevation auth failure: `ElevationModal` shows the message inline; no session state changes; no
  window opened (existing behavior). `pendingElevatedAction` is left untouched only on success —
  clear it on cancel/failure to avoid a stale replay.
- `SessionPolicy_Update` out-of-bounds → `Status=0` + message; UI keeps the prior value.
- Watcher must never throw into the UI (guard `except (Exception, java.lang.Exception)` per the
  Jython/Java-exception rule); a watcher error must not freeze the terminal.

## Testing
- **SQL (harness):** `SessionPolicy_Get` returns the single row; `SessionPolicy_Update` happy path
  + bounds rejection + audit ConfigLog row with field-diff Description; seed presence.
- **`AuthenticateAd`** already covered by `0020_PlantFloor_Foundation/025_AppUser_AuthenticateAd.sql`
  — unchanged.
- **Behavioral (manual / Designer):** elevate once → nav menu unlocks; second protected action in
  the window does not re-prompt; 5-min idle (or shortened via policy) ends the window → default
  screen + initials prompt; Reset Terminal clears elevation + operator; operator-presence timeout
  fires the re-confirm; die-cast cell change fires the re-confirm; supervisor actions in the window
  attribute to the supervisor's `AppUser.Id` in the audit log.

## Decomposition note
The remaining FAT design clusters — **#17 Hold management UX** and **#21 finished-goods
close/inventory lifecycle** — are independent subsystems and get their own spec → plan cycles
after this one.
