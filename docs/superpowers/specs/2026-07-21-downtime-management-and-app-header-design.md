# Downtime Management + App Header — Design

**Date:** 2026-07-21
**Author:** Blue Ridge Automation
**Status:** Approved (design); to be built in 3 increments, each with its own plan.
**Arc:** Arc 2 Plant Floor — Operations (`Oee`) + plant-floor chrome.

## Problem

Downtime *recording* works (smoke-tested 2026-07-21: `DowntimeEvent_Start/End`,
`DowntimeReasonCode_Assign`, `GetOpenByLocation` — full lifecycle verified), but:

1. It is a standalone full page (`/shop-floor/downtime`) with a **manual machine
   dropdown**, not scoped to the terminal.
2. Only **open** events can be acted on — no history, no editing closed events, no
   correcting times, no logging a past event, no void.
3. The plant-floor top dock is `Views/Dev/TestNavHeader` — a dev scaffold (red "DEV
   NAV" bar, 24 nav buttons), not production chrome.

MPP wants: a real **app header** on every terminal with a **downtime button** (opens
a popup), a live clock, terminal/context metadata, and an **elevated-login** button;
and the downtime popup to let an operator **retroactively CRUD** downtime events for
their **line/area (terminal-scope dependent)** during the current shift and previous
shifts.

## Goal

Replace the dev top-dock with a production **App Header**, and deliver a
**terminal-scoped Downtime Manager popup** with full, fully-audited CRUD over
downtime events, plus the SQL foundation that enables it.

**Non-goals:** the downtime/OEE **dashboard** (separate future effort, already noted
in `notes/2026-07-21_downtime-dashboard-need.md`); PLC auto-downtime commissioning
(`_WATCH=[]` stub); the OEE availability rollup.

## Confirmed decisions (Jacques, 2026-07-21)

1. **Scope = the terminal's resolved "downtime unit" location**, keyed on the active
   cell (`session.custom.cell.locationId`):
   - Cell whose **parent is a WorkCenter** → scope = **that line (WorkCenter)**
     (machining/assembly; equals the `zoneLocationId` already used for WIP).
   - Cell whose **parent is an Area** (die-cast press, no line) → scope = **the cell
     itself** (the selected press).
   Events are **logged against that scope location**; any terminal on the line acts
   on the same line-level downtime. Reads use scope **+ descendants**.
2. **Full CRUD**, all in the popup: start/stop live, edit reason+remarks, edit
   start/end times, add a fully-past event, void (soft). **Every action audited** —
   emphasized as critical for this content (retroactive edits rewrite history).
3. **Window:** default = current open shift's events in scope; a control pages to
   **previous shifts**.
4. **No elevation gate on downtime** — all operations allowed with initials
   attribution (`session.custom.appUserId`). The header's Elevated-Login button
   serves *other* protected actions, not downtime.

## Architecture

Three independently-shippable increments over one SQL foundation:

```
Increment 1 — SQL foundation (Oee)
  ufn_ResolveDowntimeScope  read: GetByScope   mutations: UpdateReason / UpdateTimes /
                                                RecordHistorical / Void  + Start/End (exist)
  migration: Oee.DowntimeEvent += VoidedAt/VoidedByUserId/VoidReason; audit event-type seeds

Increment 2 — App Header (replaces TestNavHeader in the top dock)
  Views/ShopFloor/AppHeader : clock · context meta · operator · Downtime btn ·
                              Elevated-Login btn · dev-menu toggle · "line down" pill

Increment 3 — Downtime Manager popup (consumes Inc 1, opened by Inc 2)
  Components/Popups/DowntimeManager : shift selector · event list · CRUD editors
```

### 1. Scope resolver
**`Oee.ufn_ResolveDowntimeScope(@CellLocationId BIGINT) RETURNS BIGINT`** — walks one
level up the Location hierarchy:
- parent `LocationType.Code = 'WorkCenter'` → return the parent id (the line).
- else → return `@CellLocationId` (die-cast press / self).
- NULL / not found → NULL (caller handles the fallback-terminal / no-cell case).

Deterministic from the location model (tiers: Facility → Area → WorkCenter → Cell).
Reused by every downtime proc and by the header/popup via a thin Python wrapper. This
is SQL (business rule), never Python (per `feedback_no_business_logic_in_python`).

### 2. SQL foundation (Increment 1)

**Migration (versioned):**
- `Oee.DowntimeEvent` += `VoidedAt DATETIME2(3) NULL`, `VoidedByUserId BIGINT NULL FK
  AppUser`, `VoidReason NVARCHAR(500) NULL`. (Soft void — append-only convention; no
  hard delete.)
- Seed `Audit.LogEventType`: `DowntimeReasonChanged`, `DowntimeTimesEdited`,
  `DowntimeRecordedHistorical`, `DowntimeVoided` (explicit-Id inserts, ASCII-only,
  guarded — matching the 0026 audit-seed pattern).
- `Oee.ufn_ResolveDowntimeScope` (in a repeatable, or the migration).

**Read proc — `Oee.DowntimeEvent_GetByScope`**
`@ScopeLocationId BIGINT, @IncludeDescendants BIT = 1, @ShiftId BIGINT = NULL`
- Returns **open and closed** (and voided, flagged) events whose `LocationId` is the
  scope (or a descendant when `@IncludeDescendants=1`), for the given shift
  (`@ShiftId NULL` = current open shift; caller pages previous shifts by passing an
  id from `Shift_List`).
- Columns: `DowntimeEventId, LocationId, LocationCode, ScopeLocationId,
  DowntimeReasonCodeId, ReasonCode, ReasonDescription, SourceCode, StartedAtEt,
  EndedAtEt, DurationMinutes, Remarks, AppUserId, OperatorInitials, IsOpen, IsVoided,
  VoidReason`. Timestamps ET at the read boundary (OI-36 pattern). Oldest-first.
- Descendant matching reuses the WIP subtree approach
  (`Lot_GetWipQueueByLocation @IncludeDescendants`) — closure/adjacency walk from
  scope.

**Mutation procs** (three-tier errors; single `SELECT @Status,@Message[,@NewId]`;
no OUTPUT params — FDS-11-011; **every path audited to `Audit.OperationLog` with
resolved-name Old/New JSON** per the audit convention):
- `DowntimeEvent_Start` / `DowntimeEvent_End` — **exist**; Start changes only in that
  the caller now passes the **resolved scope** location (`ufn_ResolveDowntimeScope`),
  so live events log at the line/press, not the raw cell. (Verify B3 one-open-per-
  Location still holds at the scope grain.)
- `DowntimeEvent_UpdateReason(@Id,@DowntimeReasonCodeId,@AppUserId,...)` — **allows
  changing** an already-set reason (unlike B7 `DowntimeReasonCode_Assign`, which
  refuses overwrite and stays for the PLC late-bind path). Audits `DowntimeReasonChanged`.
- `DowntimeEvent_UpdateTimes(@Id,@StartedAtEt,@EndedAtEt,@AppUserId,...)` — retroactive
  time correction. Inputs ET; converts ET→UTC at the boundary (inverse of the read).
  Validates `EndedAt > StartedAt` (or both-NULL-end for still-open); rejects a
  voided event. Audits `DowntimeTimesEdited` (Old/New times).
- `DowntimeEvent_RecordHistorical(@ScopeLocationId,@StartedAtEt,@EndedAtEt,
  @DowntimeReasonCodeId,@Remarks,@AppUserId,...)` — inserts a fully-past **closed**
  event (both times known), Source = `Operator`, stamped to the shift covering
  `@StartedAt`. Audits `DowntimeRecordedHistorical`.
- `DowntimeEvent_Void(@Id,@VoidReason,@AppUserId,...)` — sets `VoidedAt/By/Reason`;
  rejects double-void. Audits `DowntimeVoided`. Voided events stay in reads (flagged),
  excluded from any future rollup.

**Reused:** `Shift_GetOpen` (current), `Shift_List` (previous-shift picker),
`DowntimeReasonCode.search` (reason dropdown).

### 3. App Header (Increment 2) — `Views/ShopFloor/AppHeader`
Replaces `TestNavHeader` as the **`top` shared dock** (`page-config` sharedDocks
`dev-nav` → point at `AppHeader`; keep size ~56–64). Production terminals auto-route
via `HomeRouter`, so the header carries **no page-nav buttons**.

Contents (left→right):
- **Brand / terminal**: terminal name + resolved scope label (line/press);
  "Madison Facility" when on the fallback terminal.
- **Live clock**: ET date + time (self-updating).
- **Shift**: current shift name/times (from `Shift_GetOpen`).
- **Operator**: initials / presence (`session.custom.user.initials`).
- **"Line down" pill**: red when the scope currently has an open downtime (mirrors
  the existing "Paused" pill styling); reads `GetByScope` open-count.
- **Downtime** button → `openPopup` DowntimeManager.
- **Elevated Login** button → Ignition standard AD auth challenge
  (`system.perspective.login` / IdP); header reflects the elevated identity. Scope of
  this button is deliberately minimal (affordance for other protected actions); it
  does **not** gate downtime. May ship as a thin first cut.
- **Dev menu** toggle → `toggleDock('LeftDock')` so the existing `DevLauncher`
  stays reachable during dev.

`TestNavHeader` / `DevLauncher` are retained (dev), just no longer the default top
dock. Uses the canonical `psc-pf-*` / `--mpp-accent-NN` tokens (Core stylesheet;
bare `--mpp-accent` is undefined — see `project_mpp_core_stylesheet_canonical`).

### 4. Downtime Manager popup (Increment 3) — `Components/Popups/DowntimeManager`
Opened from the header; resolves scope from the session; initials-attributed; audited.
- **Header row:** scope label + **shift selector** (current + previous via `Shift_List`).
- **Event list** (flex-repeater of a `DowntimeEventRow`): Start/End (ET), duration,
  reason, source, remarks, status chip (Open / Closed / Voided). Row actions: **End**
  (open only), **Edit** (reason/times/remarks), **Void**.
- **Actions bar:** **Start downtime** (open now, optional reason), **Add past event**
  (start+end known).
- **Editor** (sub-popup or inline panel) for edit / add-past: reason dropdown
  (`DowntimeReasonCode.search`), ET start/end fields (HH:MM + date, following the
  Shift-editor `date-time-input` + text pattern and its lessons —
  `feedback_ignition_runscript_list_arg_qv_array`, java.util.Date value type), remarks.
- Every mutation → toast (`Common.Ui.notifyResult`) + list refresh (page-scoped
  message, per `feedback_ignition_message_scope`).

### 5. Python (Core)
`BlueRidge.Oee.Downtime` (extend the existing `DowntimeEvent` module or a new one):
`resolveScope(cellLocationId)`, `getByScope(scopeLocationId, includeDescendants,
shiftId)`, `updateReason`, `updateTimes`, `recordHistorical`, `void`, plus the shift
list helper. Thin wrappers (`execList/execOne/execMutation`), `_u()` unwrap at entry,
`appUserId` defaults to `_currentAppUserId()`. No business logic.

## Data flow (popup)
1. Open → `resolveScope(session.custom.cell.locationId)` → `getByScope(scope, 1,
   currentShiftId)` → list renders.
2. Any action (start/end/edit/void/add-past) → proc → audited → toast → page-scoped
   refresh → list + header pill re-read.
3. Shift selector change → re-`getByScope` with the chosen `@ShiftId`.

## Error handling / audit
- Procs follow the three-tier status-row contract; the popup surfaces `Message`.
- **All mutations audited** to `Audit.OperationLog` with resolved-name Old/New JSON
  (`LocationId:{Id,Code,Name}`, reason sub-object, ET times), `Audit.ufn_TruncateActivity`
  cap. Read procs emit no audit.
- Time inputs are **ET**; stored **UTC** (`GETUTCDATETIME`), converted ET↔UTC at the
  proc boundary both ways.

## Testing / verification
- **Inc 1:** sqlcmd tests per mutation (INSERT-EXEC into temp table, assert), incl.
  resolver returns line for an M&A cell and self for a die-cast press; GetByScope
  subtree; void flagging; ET↔UTC round-trip; audit rows written.
- **Inc 2:** `scan.ps1`; load plant-floor app — header renders on every screen,
  clock ticks, downtime button opens the popup, dev toggle still opens DevLauncher.
- **Inc 3:** create/end/edit-times/change-reason/add-past/void end-to-end in the app;
  confirm scope correctness (M&A line vs die-cast press), shift paging, and an
  `Audit.OperationLog` row per action.

## Known limitations / deferred
- **Elevated Login** ships minimal (auth challenge + identity reflect); fine-grained
  per-action gating is out of scope (downtime is explicitly ungated).
- **Fallback terminal** (unregistered IP) resolves scope to the whole Facility →
  the popup shows plant-wide downtime; acceptable for dev/supervisor, surfaced via the
  "Madison Facility" label.
- No overlap/again validation beyond `EndedAt>StartedAt` and B3 one-open-per-scope.
- Dashboard, PLC commissioning, availability rollup — separate efforts.

## Blast Radius Analysis

Enumerated from a full sweep of every `Oee.DowntimeEvent` reference (SQL + Ignition)
and every `DowntimeEvent_Start` / `session.custom.cell` writer.

### Schema change — `0043` adds `VoidedAt/VoidedByUserId/VoidReason` — **LOW (additive)**
- All nullable, no default. Every writer uses an **explicit column list**
  (`DowntimeEvent_Start`, `EndOfShiftEntry_Submit`) → inserts unaffected. **No
  `SELECT *`** on the table anywhere (verified) → existing reads
  (`GetOpenByLocation`, `GetOpenSummary`) never see the new columns.
- `clear_demo.sql` (`DELETE FROM Oee.DowntimeEvent`) and `seed_demo.sql` (proc insert)
  unaffected. Existing `sql/tests/0026_PlantFloor_Downtime_Shift/*` don't reference the
  new columns → stay green.
- `Void` also sets `EndedAt`, so a voided event drops out of the open-based reads/
  summary automatically — no retrofit of existing reads required.

### Recording location cell → resolved line scope — **MEDIUM, contained by NOT touching `Start`**
- **Key mitigation:** `DowntimeEvent_Start`'s signature/behaviour is **unchanged** — the
  *caller* supplies the location. Only the new popup passes the resolved **line**;
  every existing caller keeps passing its **cell**. So **zero forced changes** to: the
  old `DowntimeEntry` page, the `DowntimePlc` watcher (stub), `EndOfShiftEntry` breaks,
  `seed_demo`, and all eight `0026` tests.
- **Consequence — mixed grain:** new manager events at the line; legacy/break/PLC events
  at the cell. Reconciled by the read: `GetByScope(line, IncludeDescendants=1)` walks the
  line **and its descendant cells**, so it shows both. Legacy exact-match reads keep
  working at their grain.
- **B3 one-open invariant now spans grains:** a line-open (manager) and a cell-open
  (break/PLC) coexist — different `LocationId`s. Acceptable (machine break vs line down
  are distinct), but the "one open" guarantee is per-location, not per-line-subtree.

### Old `DowntimeEntry` page (`/shop-floor/downtime`) — **retire after Inc 3 (decision)**
- The popup is a superset (scope-aware, closed events, full CRUD). After Inc 3 verifies,
  retire the route + `DowntimeEntry` view + its `EventRow` to avoid two divergent
  downtime UIs writing at different grains. Not deleted by this spec's increments —
  flagged as a **follow-up cleanup**, not a blocker.

### `EndOfShiftEntry` breaks — **keep at cell (no change)**
- Breaks are operator/cell time, not line-down; correct at the cell. `GetByScope`
  (+descendants) still rolls them up under the line for future availability math. No
  change to `EndOfShiftEntry_Submit` or its test.
- `ShiftEndSummary` keeps reading open downtime **by cell** (`getEndOfShiftSummary` →
  `GetOpenByLocation`); a line-level machine-down logged via the popup won't appear there
  until `ShiftEndSummary` optionally moves to `GetByScope`. Minor follow-up, not a blocker.

### `UpdateReason` vs B7 `DowntimeReasonCode_Assign` — **coexist**
- `Assign` (refuses overwrite) stays for the PLC late-bind path; new `UpdateReason`
  (allows change) is the popup's. Two setters, distinct callers — documented so a future
  refactor doesn't collapse them wrongly.

### `TestNavHeader` replacement (Inc 2) — **MEDIUM, DEV-only**
- Production sets `session.custom.cell` via `Terminal.applyToSession` (terminal
  registration), **not** `TestNavHeader` → production unaffected.
- **Dev impact:** `TestNavHeader` is the **only** thing that sets `session.custom.cell`
  on a click; `DevLauncher` does **not** (verified: 0 refs). Removing it as the dock
  removes the one-click dev cell-setter. **Mitigation:** keep `TestNavHeader` reachable at
  `/dev/test-nav` (retained), reachable via the AppHeader dev-menu → DevLauncher; consider
  adding cell-set shortcuts to DevLauncher later. Dev-ergonomics note, not a production
  issue. No code references the `dev-nav` dock id.

### Not affected (false-positive grep hits)
- `Common/Nav`, `Location/Location`, `Quality/DefectCode`, `DowntimeReasonType`, Config
  `AuditLog`/`Sidebar`/`NewOperationTemplate` matched "downtime" via
  `DowntimeReasonCode`/type or comments — none touch `Oee.DowntimeEvent`.

### Regression gates (run to prove no regression)
- After **Inc 1**: run `sql/tests/0026_PlantFloor_Downtime_Shift/*` → all green (schema add
  + new procs don't alter existing procs).
- After **Inc 2**: existing shop-floor screens still render under the new header; dev can
  still set a cell (via `/dev/test-nav`) and open DevLauncher.

## Build order
1. **Increment 1 (SQL)** — its own plan; build + sqlcmd-verify first (everything
   depends on it).
2. **Increment 2 (App Header)** — its own plan.
3. **Increment 3 (Downtime Manager popup)** — its own plan.
Each increment: plan → implement → verify → commit, before the next.
