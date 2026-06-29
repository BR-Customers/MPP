# Arc 2 Phase 8 — Downtime + Shift Boundary — Design Spec

**Date:** 2026-06-16
**Author:** Blue Ridge Automation (Hunter)
**Status:** Draft for review
**Source plan:** `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` (v1.3) § "Phase 8 — Downtime + Shift Boundary (Parallel Track)"
**Upstream requirements:** FDS § 9.3–9.4 (FDS-09-005, -008, -009, -010, -013, -014, -015), Data Model v1.9q § 6 (Oee), UJ-10 / UJ-14 / OI-03.

---

## 1. Context & Goal

Phase 8 delivers the Downtime + Shift-boundary surface of the plant floor: PLC-driven and manual downtime entry, the FDS-09-013 end-of-shift time entry, the FDS-09-015 shift-end summary, and a supervisor dashboard. It is the designated **Parallel Track** — its only hard dependency is Phase 1 (Shift lifecycle + foundation), which is **built and on `main`** (migration `0020`). It does **not** depend on Phases 2–7.

This is a single combined spec (SQL + Ignition + Gateway). It feeds one implementation plan.

### 1.1 What is already built (Phase 8 stands on this)

| Artifact | Where | Note |
|---|---|---|
| `Oee.Shift` + `Oee.ShiftSchedule` tables | migration `0009` | ShiftSchedule has **no** break/lunch columns (see §3.2) |
| `Oee.Shift_Start` / `_End` / `_GetActive` / `_GetOpen` / `_List` | repeatable procs | Shift runtime lifecycle |
| `ShiftBoundaryTicker` Gateway timer | `ignition/projects/MPP/.../timer/ShiftBoundaryTicker/` | Creates `Shift` rows at scheduled boundaries |
| `Oee.DowntimeReasonType` (6 seed rows) | migration `0009` | Equipment / Miscellaneous / Mold / Quality / Setup / Unscheduled — **no Break/Lunch type** |
| `Oee.DowntimeReasonCode` (+ CRUD, BulkLoadFromSeed) | migration `0009` + repeatable | `AreaLocationId` is **NOT NULL**; no duration column |
| `Oee.DowntimeSourceCode` (Manual / PLC) | migration `0009` | |
| Downtime Codes Config Tool admin surface | `BlueRidge/Views/Oee/DowntimeCodes` | Reason-code CRUD UI |
| `Lots.LotPause_Place` / `_Resume` / `_GetByLocation` / `_GetByLot` / `_GetCountsByLocation` | repeatable procs | **Reference pattern** for `DowntimeEvent_*`; `_GetByLocation` is the summary's "open pauses" read |
| `Lots.Lot`, `Lots.LotMovement`, `Lots.v_LotDerivedQuantities` | migrations `0020`/`0021` | Summary's in-process-LOT read |
| Terminal flavor + initials presence (`BlueRidge.Location.Terminal`, `PresenceIdleWatcher`) | Core/MPP projects | dedicated vs shared identity capture for D3 |
| `Audit.Audit_LogOperation` | repeatable proc | Shop-floor operation audit writer (FDS-11-001) |

### 1.2 What is net-new (this phase)

`Oee.DowntimeEvent` table + a `DowntimeReasonCode` column delta + break/lunch seed + audit seeds; five procs; two Ignition entity-script modules + NQs; four Perspective views; two Gateway scripts; one SQL test suite.

---

## 2. Scope & Deliverables

Five sub-deliverables. Per the agreed scope (**full phase, external dependencies stubbed**):

| | Deliverable | This phase builds | Stub / defer |
|---|---|---|---|
| **D1** | Manual Downtime Entry | `DowntimeEvent` table + `_Start` / `_End` / `DowntimeReasonCode_Assign` procs + Downtime Entry view | — |
| **D2** | PLC Downtime ingestion | `DowntimePlcWatcher` Gateway script + the procs it calls; **verified against a tag simulator** | Live TOPServer tag wiring = commissioning-time (Phase 6 territory) |
| **D3** | End-of-Shift Time Entry | `EndOfShiftEntry_Submit` proc + End-of-Shift Time Entry view + `EndOfShiftWindowTrigger` | — |
| **D4** | Shift-end Summary | `Shift_GetEndOfShiftSummary` proc + Shift-end Summary view | — |
| **D5** | Supervisor Dashboard | Native tiles (open-downtime summary, paused-LOTs, shift-availability) | AIM-pool + print-failure tiles → **stubbed, wired in Phase 7** |

---

## 3. Key Decisions

### 3.1 Full phase, external dependencies stubbed
D2's proc + watcher are built and **simulator-verified**; live PLC wiring is deferred to commissioning. D5's Phase-7-sourced tiles (AIM pool depth, print-failure stranded count) ship as visible **stub tiles** with a "Phase 7" placeholder, so the dashboard layout is complete and the tiles light up when Phase 7 lands.

### 3.2 Break model — fixed reason codes, uniform durations (recorded divergence)

**FDS-09-013 wording:** *"The shift schedule defines the lunch and breaks for that shift… durations and start times populated from the shift schedule's break configuration."* No such configuration exists — not in the as-built `Oee.ShiftSchedule`, not in **Data Model v1.9q**, and not in the FDS-09-012 import fields.

**Decision (agreed):** model lunch/breaks as **fixed `DowntimeReasonCode` rows with a uniform standard duration**, not per-schedule configuration. Concretely:

- Add `StandardDurationMinutes INT NULL` to `Oee.DowntimeReasonCode` (populated only on break/lunch codes).
- Seed a `Break` `DowntimeReasonType` (next Id = 7) for OEE classification.
- Seed `Lunch` / `Break 1` / `Break 2` reason codes under that type, with their `StandardDurationMinutes`, **scoped to the Site-level `Location`** (HierarchyLevel 1) rather than a production Area. Rationale: breaks are plant-wide, and Site-scoping keeps them **out of the per-machine area-filtered downtime picker** (FDS-09-005) — they are end-of-shift-only, not selectable as machine downtime reasons.
- `EndOfShiftEntry_Submit` writes one **closed** `DowntimeEvent` per selected break: `StartedAt` = the shift's `ActualStart` (nominal), `EndedAt` = `StartedAt + StandardDurationMinutes`. Only the **duration** is semantically meaningful (availability = shift window − Σ downtime), so a nominal start time is acceptable under the uniform model.

**Divergence is documented, not silent.** This departs from FDS-09-013's per-schedule wording and from the "start times resolved from the schedule" clause. The spec records it; a reconciliation item is raised (§9, OI). If MPP's breaks turn out to differ per shift, the upgrade path is the `Oee.ShiftScheduleBreak` child table considered and set aside during design — additive, no rework of the event/proc shape.

### 3.3 One combined spec → one implementation plan
SQL + Ignition + Gateway in this single design doc; the implementation plan will still sequence SQL-first internally (migration + procs + tests green before front-end), but as one plan, not two specs.

---

## 4. SQL Layer

### 4.1 Migration `0026_arc2_phase8_downtime_shift.sql`

> **Migration number:** disk high-water on `main` is `0025`. Phase 8 = `0026`. (The plan's "0027" is its relative-numbering placeholder; re-baseline to actual high-water per the plan's own drift note.)

**New table — `Oee.DowntimeEvent`** (Data Model v1.9q § 6, append-only):

| Column | Type | Notes |
|---|---|---|
| `Id` | BIGINT IDENTITY PK | |
| `LocationId` | BIGINT FK → Location.Location, NOT NULL | Machine / Cell |
| `DowntimeReasonCodeId` | BIGINT FK → Oee.DowntimeReasonCode, NULL | Late-binding (B7) |
| `ShiftId` | BIGINT FK → Oee.Shift, NULL | Shift it started in (FDS-09-010) |
| `StartedAt` | DATETIME2(3) NOT NULL | Never overwritten |
| `EndedAt` | DATETIME2(3) NULL | NULL while open |
| `DowntimeSourceCodeId` | BIGINT FK → Oee.DowntimeSourceCode, NOT NULL | Manual / PLC |
| `AppUserId` | BIGINT FK → Location.AppUser, NULL | NULL for PLC-opened, no operator |
| `ShotCount` | INT NULL | Warm-up shots (UJ-14, Setup type) |
| `Remarks` | NVARCHAR(500) NULL | |
| `CreatedAt` | DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME() | |

Indexes / constraints:
- Filtered UNIQUE `UX_DowntimeEvent_OneOpenPerLocation ON (LocationId) WHERE EndedAt IS NULL` — at-most-one-open per machine (B3).
- `IX_DowntimeEvent_Shift (ShiftId, StartedAt)` — shift availability rollup.
- `IX_DowntimeEvent_OpenByLocation (LocationId) WHERE EndedAt IS NULL` — summary + entry reads.

**Delta — `Oee.DowntimeReasonCode`:** `ALTER TABLE … ADD StandardDurationMinutes INT NULL;`

**Seeds:**
- `Oee.DowntimeReasonType`: `(7, N'Break', N'Break')`.
- `Oee.DowntimeReasonCode`: `Lunch` / `Break 1` / `Break 2` (Site-scoped `AreaLocationId`, `DowntimeReasonTypeId = 7`, `StandardDurationMinutes` per MPP standard — placeholder values 30/15/15 pending MPP confirmation; seed values are a deployment data point, not a code blocker).
- `Audit.LogEntityType`: `(47, N'DowntimeEvent', …)` *(verify high-water at build — Phase-3 stale-base collision lesson).*
- `Audit.LogEventType`: `(37, N'DowntimeStarted')`, `(38, N'DowntimeEnded')`, `(39, N'DowntimeReasonAssigned')`, `(40, N'EndOfShiftSubmitted')`, `(41, N'ShiftHandoverAcknowledged')` *(verify high-water at build).*

> **Note:** verify the `Lots.LotMovement (ToLocationId, MovedAt DESC)` index already exists from Phase 1 (`0020`) — FDS-09-015 relies on it for the in-process-LOT read; add only if missing.

### 4.2 Procs (all repeatable `R__Oee_*`)

Conventions (all procs): FDS-11-011 (no `OUTPUT` params; `@Status`/`@Message`[/`@NewId`] locals; single terminal `SELECT`); three-tier error hierarchy + nested TRY/CATCH failure logging per `_TEMPLATE_stored_procedure.sql`; schema-qualified refs; audit via `Audit.Audit_LogOperation` **inside** the mutation transaction; readability convention on audit `Description` (`SUBJECT · CATEGORY · ACTION`, `ufn_MidDot` / `ufn_TruncateActivity`, resolved-FK JSON); ET conversion (`AT TIME ZONE`) on all displayed timestamps in read procs (OI-36). **Mirror the `Lots.LotPause_*` procs** for shape.

| Proc | Params | Behaviour | Output |
|---|---|---|---|
| `Oee.DowntimeEvent_Start` | `@LocationId`, `@DowntimeReasonCodeId NULL`, `@DowntimeSourceCodeId`, `@ShotCount NULL`, `@AppUserId NULL`, `@TerminalLocationId` | Insert open event. Reject if an open event already exists for `@LocationId` (B3). Resolve `@ShiftId` from the active shift. Audit `DowntimeStarted`. | `Status, Message, NewId` |
| `Oee.DowntimeEvent_End` | `@DowntimeEventId`, `@Remarks NULL`, `@AppUserId`, `@TerminalLocationId` | Set `EndedAt`. Reject if already closed. Audit `DowntimeEnded`. | `Status, Message` |
| `Oee.DowntimeReasonCode_Assign` | `@DowntimeEventId`, `@DowntimeReasonCodeId`, `@AppUserId`, `@TerminalLocationId` | Late-binding reason assignment. **Refuse overwrite** if reason already set (B7). Audit `DowntimeReasonAssigned`. | `Status, Message` |
| `Oee.EndOfShiftEntry_Submit` | `@ShiftId`, `@CellLocationId`, `@BreaksSelectedJson` (array of DowntimeReasonCode Ids), `@AppUserId`, `@TerminalLocationId` | Validate shift open + `@AppUserId` is the shift operator. For each selected break code: insert a **closed** `DowntimeEvent` (`StartedAt`=shift ActualStart, `EndedAt`=+`StandardDurationMinutes`, source=Manual, `ShiftId`=@ShiftId). Zero selected = valid (no rows). Audit `EndOfShiftSubmitted` (event-count in narrative). | `Status, Message, EventCountInserted` |

These are the **four entry/mutation procs**. The shift-end summary is **not** a single proc — FDS-11-011 forbids the three-result-set shape the plan implies — so it is delivered as three sibling read procs bundled in the entity script. See §4.3.

### 4.3 Shift-end summary read (FDS-09-015)

Three reads, scoped to the terminal's Cell + descendants:
1. **Open downtime** — `Oee.DowntimeEvent WHERE EndedAt IS NULL AND LocationId IN (cell subtree)`; resolve reason + operator + ET `StartedAt`. New proc `Oee.DowntimeEvent_GetOpenByLocation` (mirrors `LotPause_GetByLocation`).
2. **Open pauses** — reuse existing `Lots.LotPause_GetByLocation`.
3. **In-process LOTs** — `Lots.LotMovement` (latest-per-LOT via the `(ToLocationId, MovedAt DESC)` index) joined to `Lots.v_LotDerivedQuantities`. New read proc `Oee.Lot_GetInProcessByLocation` (or reuse an existing Phase-2 read if one matches — verify at build).

**Decision:** D4 uses the **three-sibling-procs** approach (clean, each obeys the single-result-set rule); `BlueRidge.Oee.Shift.getEndOfShiftSummary()` bundles the three into one dict for the view. `Oee.Shift_GetEndOfShiftSummary` is therefore a thin convenience not strictly required; we build the three reads and the entity bundler.

### 4.4 Test suite `sql/tests/0026_PlantFloor_Downtime_Shift/`

Mirror the plan's coverage (target 60–80 assertions, `test.Assert_*` framework):

| File | Covers |
|---|---|
| `010_DowntimeEvent_lifecycle.sql` | Start + End; double-start rejects (B3); end-with-no-open rejects |
| `020_DowntimeReasonCode_Assign.sql` | Late-bind succeeds; overwrite rejects (B7) |
| `030_DowntimeEvent_PLC_pattern.sql` | PLC source, NULL reason at start, reason assigned later, AppUser NULL |
| `040_DowntimeEvent_warmup_shotcount.sql` | UJ-14 ShotCount on Setup-type events |
| `050_EndOfShiftEntry_Submit.sql` | Closed break rows with correct durations; zero-selected writes nothing; non-open shift rejects; second submission rejects |
| `060_ShiftEndSummary_reads.sql` | Three reads return correct cell-scoped rows; ET conversion; in-process read uses the LotMovement index |
| `070_OpenEvents_span_boundary.sql` | `Shift_End` leaves open DowntimeEvent / PauseEvent rows untouched (UJ-10 / OI-03) |
| `080_audit_shape.sql` | Convention-shape assertions on `DowntimeStarted` / `EndOfShiftSubmitted` Description + resolved-FK JSON |

---

## 5. Ignition Layer

### 5.1 Entity scripts + Named Queries
- **`BlueRidge.Oee.DowntimeEvent`** (new): `start`, `end`, `assignReason`, `getOpenByLocation`, `submitEndOfShift`, `getEndOfShiftSummary` (bundles the three reads). Routes through `Common.Db`; returns plain `list[dict]`. **No business logic in Python** (durations/validation live in SQL).
- **`BlueRidge.Oee.Shift`** (extend): add `getActiveForTerminal` / window helpers if not present.
- NQ wrappers (thin `EXEC`) under `named-query/oee/`: `DowntimeEvent_Start` / `_End` / `_Assign` / `EndOfShiftEntry_Submit` / `DowntimeEvent_GetOpenByLocation` / `Lot_GetInProcessByLocation`. Mutation NQs use `type: "Query"` (status-row SELECT) per `feedback_ignition_nq_type_for_status_row_procs`.

### 5.2 Perspective views (4 purpose-built top-level views)

Conventions: file-authored new views (safe — no Designer cache); flex-repeater rows as sibling sub-views under `Components/PlantFloor/...` (never nested under a view); up/down arrows not drag-drop; `position.display` for conditional flex; route registered in `page-config/config.json`; HomeRouter tile.

| View | Key content |
|---|---|
| **Downtime Entry** | Open-events flex-repeater at the terminal's Cell scope (per-event row sub-view: machine, source, reason-or-`Assign`, `StartedAt` ET, End button). Start-new form: machine (scoped), optional reason (area-filtered, FDS-09-005), optional ShotCount (visible only when reason type = Setup). |
| **End-of-Shift Time Entry** | Visible only in the ±15-min window (`EndOfShiftWindowTrigger`). One **toggle button per break code** (Lunch / Break 1 / Break 2). Dedicated flavor: tap + Submit (operator from presence context). Shared flavor: inline initials field → AppUser (FDS-04-005) before Submit. Routes to Shift-end Summary on success. |
| **Shift-end Summary** (FDS-09-015) | Three read-only flex-repeaters (open downtime / open pauses / in-process LOTs) from the entity bundler. Acknowledge button → writes `ShiftHandoverAcknowledged` to `Audit.OperationLog`. Optional / skippable. |
| **Supervisor Dashboard** | Tile composition: **native** — DowntimeOpenSummary (reason / no-reason split, B7 triage), PausedLotsSummary, ShiftAvailabilityTile (derived per OI-03). **Stubbed** — AimPoolWallboardTile, PrintFailureStrandedTile (Phase 7 placeholder). |

### 5.3 Gateway scripts
- **`DowntimePlcWatcher`** (per machine) — stop edge → `DowntimeEvent_Start` (source PLC, NULL reason, AppUser NULL); run edge → `DowntimeEvent_End`. **Verified against a tag simulator**; live TOPServer binding is commissioning. Audit via the procs.
- **`EndOfShiftWindowTrigger`** — view-side timer; surfaces the End-of-Shift control from −15 to +15 min around the active shift's scheduled end. No DB state.

---

## 6. Audit

All Phase 8 mutations are shop-floor operations → `Audit.OperationLog` via `Audit.Audit_LogOperation` (FDS-11-001), **not** ConfigLog. Event types `DowntimeStarted` / `DowntimeEnded` / `DowntimeReasonAssigned` / `EndOfShiftSubmitted` / `ShiftHandoverAcknowledged`. Entity type `DowntimeEvent`. Descriptions follow the readability convention with resolved-FK (`Location`, `DowntimeReasonCode`, `Shift`) JSON sub-objects.

---

## 7. Cross-cutting conventions applied
- **FDS-11-011** — no `OUTPUT` params; one result set per proc; mutation status-row contract.
- **OI-36 ET timestamps** — store UTC, `AT TIME ZONE` at every new read-proc boundary.
- **Audit readability** — `ufn_MidDot` / `ufn_TruncateActivity` / resolved-FK JSON; `JSON_QUERY((…))` wrap; `DATALENGTH`-based trailing strip; boolean words.
- **No business logic in Python** — durations, validation, B3/B7 enforcement in SQL.
- **PowerShell BOM trap** — write `query.sql` / `view.json` with no BOM.
- **Atomic state writes** for any editor-style view custom state (not expected here — these are operator action screens, not editDraft editors).

---

## 8. Out of scope
- Live TOPServer PLC tag wiring (commissioning / Phase 6).
- AIM-pool + print-failure dashboard tiles (Phase 7 — stubbed here).
- A per-shift break-editor Config Tool surface (deferred; the `Break` codes are seeded).
- `Oee.OeeSnapshot` calculation (FUTURE).
- PD operational reports (separate Reporting workstream, UJ-19).
- `Oee.ShiftScheduleBreak` child table (set aside per §3.2; additive upgrade path if MPP needs per-schedule breaks).

## 9. Open items / risks
- **OI (new) — FDS-09-013 break-model reconciliation.** Uniform fixed-duration break codes diverge from the FDS's per-schedule wording. Raise an OIR item; confirm MPP's break/lunch durations (deployment seed values) and whether breaks ever differ per shift.
- **Audit-ID high-water** — re-verify `LogEventType` / `LogEntityType` max against the live DB at build (Phase-3 stale-base collision lesson); the 37–41 / 47 assignments assume disk high-water as of this spec.
- **`v_LotDerivedQuantities` / in-process read** — verify the exact existing view + whether a Phase-2 read proc already covers the in-process-LOT-by-location query before writing a new one.
- **Terminal flavor + initials** — confirm the exact `BlueRidge.Location.Terminal` API for dedicated/shared flavor + initials→AppUser resolution when wiring D3.
- **PLC simulator** — D2 acceptance is simulator-based; define the simulated tag set in the plan.

## 10. Phase 8 complete when
- [ ] Migration `0026` applied; `DowntimeEvent` + delta + seeds in place; full SQL suite green (existing + `0026_*`).
- [ ] All four entry/mutation procs + the three summary reads delivered to convention.
- [ ] Four Perspective views implemented + routed + HomeRouter tiles.
- [ ] `DowntimePlcWatcher` simulator-verified; `EndOfShiftWindowTrigger` surfaces the control in-window.
- [ ] End-to-end (sim): PLC opens NULL-reason downtime → operator assigns reason → at −15 min the time-entry control appears → operator submits (dedicated) → break `DowntimeEvent` rows written with correct durations → Shift-end Summary shows open events → acknowledge writes audit row → next shift closes the open downtime when the machine resumes.
- [ ] `Audit.OperationLog` rows carry the readable narrative + resolved-FK JSON for every mutation.
- [ ] FDS-09-013 divergence recorded in the OIR.
