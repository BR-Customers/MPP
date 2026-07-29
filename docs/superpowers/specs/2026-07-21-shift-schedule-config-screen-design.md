# Shift Schedules — Config Screen Design

**Date:** 2026-07-21
**Author:** Blue Ridge Automation
**Status:** Approved (design), pending implementation plan
**Arc:** Config Tool (Arc 1), Operations (`Oee`) reference data

## Problem

The Config Tool advertises a **"Shift Schedules"** nav item (`Sidebar/view.json` →
`NavItemShiftSchedules` → `/shifts`), but nothing is wired behind it:

- **SQL backend** — ✅ built. `Oee.ShiftSchedule` table + 5 CRUD procs
  (`ShiftSchedule_Create / Update / Get / List / Deprecate`), migration
  `0009_phase8_oee_reference.sql`.
- **Named Query layer** — ❌ missing. No `oee/ShiftSchedule_*` named queries exist,
  so the procs have no Ignition-callable wrapper.
- **Perspective view** — ❌ missing. Only `Views/Oee/DowntimeCodes` exists under
  `Views/Oee`.
- **Page route** — ❌ not registered. `page-config/config.json` has
  `/downtime-codes` but no `/shifts`.
- **Nav link** — ⚠️ present but dead. Clicking "Shift Schedules" lands on an
  unregistered route (blank), which is the reported "doesn't populate" symptom.

Because there is no authoring UI, shift schedules can only be created by calling
the procs directly. The runtime shift-boundary engine (`ShiftBoundaryTicker` →
`BlueRidge.Oee.Shift.tickShiftBoundary` → `Shift_Start` / `Shift_End`) has nothing
to resolve against unless a `ShiftSchedule` row is inserted manually.

## Goal

Wire the existing `Oee.ShiftSchedule_*` procs to a Config Tool screen, mirroring the
**Downtime Codes** screen pattern (`Views/Oee/DowntimeCodes` +
`Components/DowntimeCodeRow` + `Components/Popups/DowntimeCodeEditor`). Turn the dead
`/shifts` nav link into a working CRUD screen.

**Non-goals:** No SQL changes. No overlap validation. No downtime dashboard (noted as
a follow-up only). No changes to the runtime shift-boundary engine.

## Design decisions (confirmed with Jacques, 2026-07-21)

1. **Days-of-week picker = 7 toggle chips.** A row of tappable Mon–Sun chips;
   selected chips highlight. Touch-friendly, matches the no-drag/tap convention,
   reads at a glance. The editor composes `DaysOfWeekBitmask` (Mon=1, Tue=2, Wed=4,
   Thu=8, Fri=16, Sat=32, Sun=64; range 1–127) from selected chips.
2. **Time entry = HH:MM text field, 24-hour.** A masked/plain text field; the value
   passes as a string and JDBC coerces it to `TIME`. Flexible for any minute.
   Overnight shifts are handled by the proc (valid when `EndTime < StartTime`).
3. **Overlapping-schedule validation = documented limitation, not built.** Ship the
   CRUD screen with no SQL change. See Known Limitations.

## Architecture

Pure NQ + view + route layer over the existing procs. Three tiers:

```
page /shifts
  └─ Views/Oee/ShiftSchedules ......... list screen (filter bar + flex-repeater)
       ├─ Components/ShiftScheduleRow ......... one row; bitmask → compact Days label
       └─ Components/Popups/ShiftScheduleEditor  modal create/edit; day chips + times
            └─ BlueRidge.Oee.ShiftSchedule (Core Python) ... thin proc wrappers + bitmask helpers
                 └─ oee/ShiftSchedule_* (Core named queries) ... thin proc wrappers
                      └─ Oee.ShiftSchedule_* (SQL procs, already built)
```

### 1. Named Queries — 5 new, in **Core** `named-query/oee/`

All named queries live in Core per the NQ-topology convention (MPP/MPP_Config have
zero local NQs). Each is a thin wrapper over the same-named proc.

| Named query | Params | resource.json `type` | Notes |
|---|---|---|---|
| `ShiftSchedule_List` | `activeOnly` (BIT) | `Query` | Read; returns all columns |
| `ShiftSchedule_Get` | `id` (BIGINT) | `Query` | Read; empty rowset = not found |
| `ShiftSchedule_Create` | `name`, `description`, `startTime`, `endTime`, `daysOfWeekBitmask`, `effectiveFrom`, `appUserId` | `Query` | Status-row proc (`SELECT @Status,@Message,@NewId`) — `type: Query` per the status-row-proc NQ convention |
| `ShiftSchedule_Update` | as Create + `id` | `Query` | Status-row proc |
| `ShiftSchedule_Deprecate` | `id`, `appUserId` | `Query` | Status-row proc |

- `startTime` / `endTime` pass as `HH:MM` strings; JDBC coerces to `TIME(0)`.
- `effectiveFrom` passes as a date.
- `database: "MPP"`, scope `DG`, matching sibling `oee/DowntimeReasonCode_*` files.

### 2. Python wrappers — Core `BlueRidge/Oee/ShiftSchedule/code.py`

Mirrors `BlueRidge.Oee.DowntimeReasonCode`. Wrappers only; **no business logic**
beyond formatting.

- `list(activeOnly=True)` → `execList("oee/ShiftSchedule_List", ...)`
- `get(id)` → `execOne("oee/ShiftSchedule_Get", ...)`
- `create(...)` / `update(...)` / `deprecate(...)` → `execMutation(...)`, defaulting
  `appUserId` to the session-resolved current user when `None`.
- `search(filter)` → reads `list()` and applies client-side `searchText`
  (Name/Description contains) + `includeDeprecated` filtering. Returns the row shape
  the flex-repeater transform consumes.
- **Bitmask helpers (single source of truth for both row label and editor):**
  - `bitmaskToDays(mask)` → ordered list of day codes/indices selected.
  - `daysToBitmask(days)` → INT 1–127.
  - `bitmaskToLabel(mask)` → compact display string. Contiguous weekday runs collapse
    (e.g. `31 → "Mon–Fri"`, `96 → "Sat–Sun"`, `21 → "Mon Wed Fri"`).

### 3. Views (MPP_Config)

**`Views/Oee/ShiftSchedules`** — the list screen.
- Title row: breadcrumb `Operations › Shift Schedules`, `h1` "Shift Schedules",
  spacer, **"+ Add Schedule"** button opening the editor popup (`mode: "create"`,
  `scope: "G"` for `system.perspective.openPopup`).
- Filter bar (lighter than the DowntimeCodes 220px sidebar — ShiftSchedule has no
  Area/Type to filter): a **Search** text field + an **Include deprecated** checkbox,
  both bidi-bound to `view.custom.filter.*` (persistent).
- Data panel: table header + `ia.display.flex-repeater` bound to
  `view.custom.rows` (from `BlueRidge.Oee.ShiftSchedule.search`), instances shaped by
  a script transform, `path: BlueRidge/Components/ShiftScheduleRow`.
- Columns: **Name · Days · Start · End · Effective From · (edit)**.
- Page-scoped `shiftSchedulesRefresh` message handler re-seeds the filter to
  re-run the `rows` binding after an editor save/deprecate.

**`Components/ShiftScheduleRow`** — one row.
- `params.value` = one row dict (input-only). Renders Name, the compact **Days**
  label (from `bitmaskToLabel`), Start, End, Effective From.
- Edit button opens `ShiftScheduleEditor` in `mode: "edit"` with `editId`.
- Deprecated rows are visually dimmed (matches DowntimeCodeRow).

**`Components/Popups/ShiftScheduleEditor`** — modal create/edit.
- Owns `view.custom.editDraft` with the **full shape pre-seeded** (every bound key
  present: `name`, `description`, `days` list, `startTime`, `endTime`,
  `effectiveFrom`) per the bidi-nested-path and pre-declared-custom-prop conventions.
- Fields: Name (text), Description (text), **7 day-toggle chips** (Mon–Sun), Start
  (`HH:MM` text), End (`HH:MM` text), Effective From (date picker).
- On open in edit mode: loads via `ShiftSchedule_Get`, writes `selected` + `editDraft`
  in **one atomic property write**.
- On Save: composes bitmask from selected chips (`daysToBitmask`), validates required
  fields + basic `HH:MM` format client-side, calls Create/Update, toasts the result
  (`BlueRidge.Common.Notify.toast`), broadcasts `shiftSchedulesRefresh`
  (page-scoped), closes on success.
- Edit mode also exposes **Deprecate** (confirm, then `ShiftSchedule_Deprecate`,
  toast, refresh, close).
- Close/X uses the dirty-check → `ConfirmUnsaved` popup pattern where a draft is dirty.

### 4. Route + nav

- Add to `MPP_Config/.../page-config/config.json`:
  `"/shifts": { "viewPath": "BlueRidge/Views/Oee/ShiftSchedules", ... }` matching the
  `/downtime-codes` entry shape.
- **No Sidebar change** — `NavItemShiftSchedules` → `/shifts` already exists; it
  starts resolving once the route is registered.

## Data flow

1. Screen loads → `custom.rows` binding runs `ShiftSchedule.search(filter)` →
   `ShiftSchedule_List` → rows shaped by transform → flex-repeater renders
   `ShiftScheduleRow` instances (Days label via `bitmaskToLabel`).
2. "+ Add Schedule" / row edit → opens `ShiftScheduleEditor` (create / edit).
3. Editor Save → `daysToBitmask(chips)` → `ShiftSchedule_Create|Update` NQ → proc
   validates (required, bitmask range, unique name, not-deprecated) → status row →
   toast → page-scoped `shiftSchedulesRefresh`.
4. Refresh handler re-seeds `filter` → `rows` binding re-runs → list reflects change.
5. Deprecate → `ShiftSchedule_Deprecate` → same refresh path; deprecated rows show
   only when "Include deprecated" is checked.

## Error handling

- Procs already emit the three-tier status-row contract
  (`Status`, `Message`, `NewId`); the editor surfaces `Message` via toast.
- Read NQs return empty rowset for not-found (no invented 404).
- All required-field / bitmask-range / unique-name / deprecated-target rejections are
  handled server-side; the editor does light client-side pre-validation
  (required + `HH:MM` shape) for responsiveness only.

## Testing / verification

- Run `scan.ps1` after adding NQ + view + route resources; confirm the 5 NQs load
  (watch `wrapper.log` for "Named query not found").
- Manually exercise in the Config app: create → appears in list; edit → bitmask
  round-trips (chips → save → compact Days label); overnight shift (End < Start)
  accepted; deprecate → hidden unless "Include deprecated"; duplicate name rejected
  with toast.
- Confirm `/shifts` route resolves (dead-link symptom gone) and the existing Sidebar
  nav item navigates to it.
- Confirm `Audit.ConfigLog` rows written for Create/Update/Deprecate.

## Known limitations (accepted)

- **No overlapping-schedule validation.** The boundary ticker assumes at most one
  active schedule at any moment; authoring two schedules whose day+time windows
  overlap makes `Shift_GetActive` pick one nondeterministically. Documented as a
  follow-up; no SQL change in this build.

## Follow-up (noted, not built here)

- **Downtime / OEE dashboard.** A supervisor-facing dashboard is needed:
  open downtime by cell, a downtime Pareto by reason / reason-type, and availability
  once a shift-availability rollup exists. Recorded as a dated note in `notes/` and a
  line in `PROJECT_STATUS.md`. Separate spec/plan when scheduled.

## Files touched

**New:**
- `ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_List/` (+ `_Get`,
  `_Create`, `_Update`, `_Deprecate`) — `query.sql` + `resource.json` each.
- `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftSchedule/code.py`
  (+ `resource.json`).
- `ignition/projects/MPP_Config/.../views/BlueRidge/Views/Oee/ShiftSchedules/`
  (`view.json` + `resource.json`).
- `ignition/projects/MPP_Config/.../views/BlueRidge/Components/ShiftScheduleRow/`.
- `ignition/projects/MPP_Config/.../views/BlueRidge/Components/Popups/ShiftScheduleEditor/`.
- `notes/2026-07-21_downtime-dashboard-need.md`.

**Modified:**
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json`
  (add `/shifts`).
- `PROJECT_STATUS.md` (downtime dashboard follow-up line).

**Unchanged:** all `Oee.ShiftSchedule_*` SQL procs and the shift-boundary runtime.
