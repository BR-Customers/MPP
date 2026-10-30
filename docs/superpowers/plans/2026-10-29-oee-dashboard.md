# OEE Dashboard (Availability + Quality, Site -> Area -> Unit) Implementation Plan

> **Superseded 2026-10-30** by `docs/superpowers/plans/2026-10-30-oee-dashboard-v03.md` (spec v0.3.1). Tasks 1-6 here were built; kept as the record and for the column lists Tasks 11-15 of the new plan reference.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the availability, downtime and quality the plant already records in front of supervisors on three Perspective pages: site, area and unit. Performance and OEE appear as darkened future cards.

**Architecture:** All arithmetic lives in SQL. `Oee.Shift_GetAvailability` is rewritten as a table-valued function, `Oee.ufn_ShiftAvailability`. Two more functions produce per-shift good and scrap rows, and a handful of read procs pool those over a period's shifts (never average them). Ignition stays thin: Core named queries, one script module that returns shaped empty results, and three new MPP views with a small set of shared components.

**Tech Stack:** SQL Server 2022 (repeatable procs/functions, T-SQL test framework in `sql/tests/`), Ignition 8.3 Perspective (file-based views), Ignition Reporting Module.

**Spec:** `docs/superpowers/specs/2026-10-27-oee-dashboard-design.md` (v0.2, approved 2026-10-29). Read it first; section numbers below refer to it. Mockups: `docs/superpowers/specs/2026-10-27-oee-dashboard-mockups/`.

## Global Constraints

- Work on `jacques/working`; stage explicit paths only; no `Co-Authored-By` trailer. Other sessions share this checkout.
- Do not reset `MPP_MES_Dev`. Run tests with `sql/tests/Run-Tests.ps1` (defaults to the throwaway `MPP_MES_Test`).
- Repeatable objects only (`sql/migrations/repeatable/R__Oee_*.sql`). If a task finds it truly needs a versioned migration, re-check the next free number first: `0116` is the highest at plan time, and `0090`-`0092` names were claimed by specs.
- Read procs: ONE result set, no OUTPUT params, `EXEC` args literal or `@variable` only (CLAUDE.md, FDS-11-011).
- Timestamps stored UTC, displayed ET. `Oee.Shift.ActualStart` and schedule times are LOCAL (OI-38), while `RejectEvent.RecordedAt`, `Lot.CreatedAt`, `DowntimeEvent.StartedAt` and `ProductionEvent.EventAt` are UTC. Convert at the comparison boundary with `AT TIME ZONE`, as `Shift_GetAvailability` does.
- Pooled, never averaged: `Availability = SUM(Base - Unplanned)/SUM(Base)`, `Quality = SUM(Good)/SUM(Good+Scrap)` (6.3). A roll-up line contributes `Base * (1 - its mean availability)` as effective unplanned.
- Business rules in SQL, never Python (memory `feedback_no_business_logic_in_python`).
- Seed and string literals ASCII-only. All named queries live in Core. New view folders need `view.json` + `resource.json`, sit as siblings (never nested), and are registered with `.\scan.ps1`.
- Every `view.custom.*` a binding reads is pre-declared with a full-shape default, and the script behind it returns the full shape on empty (CLAUDE.md "Pre-declare every binding-referenced custom property").
- Page names: "OEE"; routes `/shop-floor/oee`, `/shop-floor/oee/area/:areaKey` (`diecast` | `trim` | `ma`), `/shop-floor/oee/unit/:locationId`.
- Colour bands: green >= 0.85, amber >= 0.70, red below, from `Oee.ufn_OeeBand` only.

## Review Focus

1. **A period with zero shifts or an anchor shift that is not found**: every proc returns an empty set (not an error), and every page shows "--" rather than a red Component Error. Test in Task 6 (`[Summary] unknown anchor -> 0 rows`), and Task 9 asserts the `OrEmpty` shapes.
2. **The shift in progress**: availability for it is shown, but labelled "in progress -- downtime not yet entered", and it is never the default. Test in Task 7 (`[Period] default anchor is last ENDED shift`).
3. **A reject recorded at a location that is not under any OEE unit** (e.g. a terminal under a SupportArea): it must not vanish silently from area quality when its charge family is a production area. Test in Task 5 (`[Scrap] cell outside any unit, DC-charged -> Die Cast area level`).
4. **A 3rd shift under an override that ends after midnight + 1h**: the production day is decided by the *scheduled* end, so it stays the same. Test in Task 4 (`[ProdDay] overridden 3rd shift keeps scheduled production day`).
5. **A die-cast press that ran two dies in one Day period**: the tile shows the latest-used die, not two rows. Test in Task 6 (`[Summary] two dies -> latest only, one row`).

---

### Task 1: Scrap writers stamp line and shift (spec 7)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_RejectEvent_RecordByPartFifo.sql` (insert ~366-377; header version + change log)
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql` (reject insert ~270-274; header version + change log)
- Test: `sql/tests/0028_PlantFloor_Assembly/102_RejectEvent_RecordByPartFifo.sql`, `sql/tests/0027_PlantFloor_Machining/080_MachiningOut_Mint_scrap.sql`

**Interfaces:** No signature changes. Produces `RejectEvent.CellLocationId` = line and `RejectEvent.ShiftId` populated on both paths.

- [ ] **Step 1: Write the failing assertions** in each existing test file, after its happy-path record:
  - `[FIFO] reject CellLocationId = @LocationId (the line)`: `Assert_IsEqual` on the newest `RejectEvent` row's `CellLocationId`.
  - `[FIFO] reject ShiftId = ufn_ShiftIdForInstant(line, now)`: expected value `(SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@Line, SYSUTCDATETIME()))`. The fixture needs an open `Oee.Shift` covering now; reuse whatever the file already opens, or add one.
  - `[Mint scrap] reject ShiftId = ufn_ShiftIdForInstant(line, now)`, same expected-value shape.
- [ ] **Step 2: Run** `.\sql\tests\Run-Tests.ps1 -Filter "RecordByPartFifo"` and `-Filter "MachiningOut_Mint_scrap"`. Expected: the new assertions FAIL (NULL actual).
- [ ] **Step 3: Implement.** RecordByPartFifo: write `CellLocationId = @LocationId` and `ShiftId = (SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@LocationId, SYSUTCDATETIME()))`, captured into a local `@ShiftId` before the insert (the same shape as `R__Workorder_TrimOut_Record.sql:378`). MachiningOut_Mint: the same, keyed on the line it already writes as `CellLocationId`. Bump versions (`RecordByPartFifo` 1.1 -> 1.2, `MachiningOut_Mint` 2.7 -> 2.8) and add change-log lines citing spec 7.
- [ ] **Step 4: Run** both filters again. Expected: PASS, and the previously passing assertions in both files still pass.
- [ ] **Step 5: Commit** `git add` the two procs and the two tests; `git commit -m "fix(sql): FIFO + mint scrap stamp line and shift for the OEE dashboard"`.

### Task 2: `Oee.ufn_ShiftAvailability` -- availability as a function (spec 6.1)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_ShiftAvailability.sql`
- Modify: `sql/migrations/repeatable/R__Oee_Shift_GetAvailability.sql` (body becomes a SELECT from the function; v3.0)
- Test: the existing `sql/tests/0059_Oee_ShiftOverride/030_availability.sql` and `sql/tests/0090_Oee_EnabledLocations/030_rollup_availability.sql`, `050_rollup_edge_cases.sql` **unchanged**, plus new `sql/tests/0117_Oee_Dashboard/010_ufn_ShiftAvailability.sql`

**Interfaces:**
- Produces: `Oee.ufn_ShiftAvailability(@ShiftId BIGINT)` -> exactly the proc's current columns in the current order (`ShiftId ... IsRollup, ParentLocationId`; see the proc header).
- `Oee.Shift_GetAvailability(@ShiftId, @LocationId = NULL)` -> `SELECT * ... FROM Oee.ufn_ShiftAvailability(@ShiftId) WHERE @LocationId IS NULL OR LocationId = @LocationId ORDER BY <current order>`.

The repeatable file name must sort before the proc's file, or the runner's ordering must create the function first. Check how `R__Oee_ufn_zz_ShiftIdForInstant.sql` handles dependency order and follow that convention.

- [ ] **Step 1: Write the parity test** `010_ufn_ShiftAvailability.sql`. Reuse the `TEST_RU_Day` fixture shape from `0090/030` (an 8-hour shift, lunch on the line, a 5-minute Machining stop, a 40-minute Assembly A jam). Assert `[ufn] Machining 0.9889`, `[ufn] Assembly A 0.9111`, `[ufn] Line mean 0.9667`, `[ufn] row count = proc row count`, and `[ufn] EXCEPT proc result is empty` (INSERT-EXEC the proc into a temp table, then `EXCEPT` both directions).
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: FAIL, function not found.
- [ ] **Step 3: Implement** the function. Prefer an inline, set-based TVF. If the one-minute grid and roll-up nesting cannot be expressed set-based, use a multi-statement TVF on table variables, replacing the `WHILE` roll-up loop with a recursive CTE over `Oee.ufn_OeeAncestors` depth. Keep v2.0.1's semantics exactly (base shrink by planned minutes, ancestor inheritance, one-minute grid, single rounding, mean roll-up, `Availability` NULL when `BaseMinutes = 0`). Then reduce the proc to a SELECT from the function and bump it to v3.0.
- [ ] **Step 4: Run** `-Filter "Oee"`. Expected: every existing availability assertion passes unchanged, plus the new file.
- [ ] **Step 5: Early cost check (not the gate).** On `MPP_MES_Test`, time `SELECT * FROM Oee.ufn_ShiftAvailability(@s)` for 21 consecutive shifts with `SET STATISTICS TIME ON`. Record the total in the commit message. If it is over 1.5 s with Dev-sized data, stop and tell Jacques before Task 3.
- [ ] **Step 6: Commit** the function, the proc and the test; `git commit -m "refactor(sql): Shift_GetAvailability v3.0 over Oee.ufn_ShiftAvailability"`.

### Task 3: Classification helpers -- area family, charge family, band (spec 6.2, 6.4, 6.5)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_AreaFamily.sql`, `R__Oee_ufn_RejectChargeFamily.sql`, `R__Oee_ufn_OeeBand.sql`, `R__Oee_ufn_OeeUnits.sql`
- Test: `sql/tests/0117_Oee_Dashboard/020_classification.sql`

**Interfaces (all inline TVFs, called with `CROSS APPLY` / `SELECT TOP 1`):**
- `Oee.ufn_OeeUnits()` -> `(UnitLocationId, UnitCode, UnitName, AreaFamily NVARCHAR(10), ProductionAreaId, ProductionAreaName, IsStation BIT, ParentUnitLocationId)`. One row per OEE-enabled location: `IsStation = 0` with no OEE-enabled ancestor (the unit), `IsStation = 1` for OEE-enabled descendants of a unit.
- `Oee.ufn_AreaFamily(@LocationId)` -> `(AreaFamily)` in `N'diecast' | N'trim' | N'ma'`, or no row. Derived from the location's own or nearest-ancestor `LocationTypeDefinition` code: `DieCastMachine` -> diecast, `TrimPress` -> trim, `ProductionLine` -> ma. A ProductionArea resolves through its child units. The Trim Shop *is* an area with presses under it, so a Trim Shop `CellLocationId` -> trim. Pick the cleanest discriminator in the seed (`sql/seeds/011_seed_locations_mpp_plant.sql`) and document it in the header.
- `Oee.ufn_RejectChargeFamily(@DefectCodeId, @FoundFamily)` -> `(ChargeFamily)`: `DieCast`/`DieMaintenance` -> diecast, `TrimShop` -> trim, `MachineShop` -> ma, `MppNonSpecific`/`SupplierNonSpecific` -> `@FoundFamily` (NULL when that is NULL).
- `Oee.ufn_OeeBand(@Ratio DECIMAL(9,4))` -> `(Band)` `N'green' | N'amber' | N'red'`, NULL for NULL.

- [ ] **Step 1: Write tests**: `[Family] each seeded DieCastMachine -> diecast` (and one each for TrimPress, Trim Shop area, ProductionLine, a station under a line -> ma); `[Charge] DieMaintenance -> diecast`; `[Charge] MppNonSpecific found at trim -> trim`; `[Charge] SupplierNonSpecific with no found family -> NULL`; `[Band] 0.8500 green, 0.8499 amber, 0.7000 amber, 0.6999 red, NULL -> NULL`; `[Units] a line with stations -> line IsStation 0, stations IsStation 1 with ParentUnitLocationId = line`. Use `test.OeeFixture_Build` (`sql/tests/helpers/0090_fixture_oee_locations.sql`) for the line and stations, and dynamic lookups for the seeded locations (memory `project_mpp_location_seed_and_disabled_tests`).
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: FAIL.
- [ ] **Step 3: Implement** the four functions.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 4: Production day and periods (spec 6.6, 5.1)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_ProductionDay.sql`, `R__Oee_ufn_ShiftsForPeriod.sql`
- Test: `sql/tests/0117_Oee_Dashboard/030_production_day.sql`

**Interfaces:**
- `Oee.ufn_ProductionDay(@ShiftId)` -> `(ProductionDay DATE)` = the local date of the shift's **scheduled** window end: `ShiftSchedule.EndTime` on the `ActualStart` date, +1 day when `EndTime <= StartTime`. Never the override end.
- `Oee.ufn_ShiftsForPeriod(@Zoom NVARCHAR(5), @AnchorShiftId BIGINT)` -> `(ShiftId, ProductionDay, SortKey)` with `@Zoom` in `N'Shift' | N'Day' | N'Week'`. Shift = the anchor. Day = every `Oee.Shift` with the anchor's production day. Week = every shift whose production day falls in the anchor's Monday-Sunday week (`DATEFIRST`-independent: compute Monday via `DATEDIFF(DAY, '19000101', d) % 7`). `SortKey` orders by `ActualStart`.

- [ ] **Step 1: Write tests** with three schedules (1st 06:30-14:30, 2nd 14:30-22:30, 3rd 22:30-06:30) and shifts from Sun 2026-10-25 22:30 to Mon 2026-10-26 22:30:
  - `[ProdDay] 3rd starting Mon 22:30 -> Tue`
  - `[ProdDay] 1st Mon 06:30 -> Mon`
  - `[ProdDay] overridden 3rd shift keeps scheduled production day` (`ActualEnd` 07:45 next day)
  - `[Period] Day of Mon 1st = {Sun 22:30 3rd, Mon 1st, Mon 2nd}, in that order`
  - `[Period] Week of Mon 1st starts with the Sun 22:30 3rd shift and holds 21 shifts` (seed the full week)
  - `[Period] Shift zoom = the anchor only`
  - `[Period] unknown anchor -> 0 rows`
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** -> PASS. **Step 5: Commit.**

### Task 5: Good and scrap per shift (spec 6.4)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_ShiftGood.sql`, `R__Oee_ufn_ShiftScrap.sql`
- Test: `sql/tests/0117_Oee_Dashboard/040_good_and_scrap.sql`

**Interfaces:**
- `Oee.ufn_ShiftGood(@ShiftId)` -> `(UnitLocationId, AreaFamily, ItemId, ToolId NULL, LastEventAt, Good BIGINT)`. The rules are in spec 6.4's table:
  - Die Cast: `DieCastContribution.PieceDelta` by `CellLocationId` and `ShiftId`. `ToolId` is the die mounted on that cell at `EventAt`; resolve it through the existing Tools mount/assignment table, and use whatever `DieCastSupervisor_GetShiftContext` already uses to name a press's die.
  - Trim: per-checkpoint credit via `Workorder.ufn_TrimPassPreviousCount`, mapped to the Trim Shop above `TerminalLocationId`; `ShiftId NULL` rows are excluded.
  - M&A: `PieceCount` of `Manufactured`-origin FinishedGood LOTs by the line above `CreatedAtTerminalId`, assigned to the shift whose window (`ufn_ShiftWindowForLocation`) contains `CreatedAt`.
- `Oee.ufn_ShiftScrap(@ShiftId)` -> `(RejectEventId, ChargeFamily, UnitLocationId NULL, FoundAtLocationId NULL, FoundFamily NULL, ItemId, DefectCodeId, Quantity BIGINT, IsNonReject BIT, IsFoundDownstream BIT)`:
  - Shift membership: `ShiftId = @ShiftId`, or `ShiftId IS NULL` and `RecordedAt` inside the found unit's shift window. For no-cell rows, use the plant `Oee.Shift` window.
  - `FoundAtLocationId` = the unit containing `CellLocationId` (via `ufn_OeeUnits` or an ancestor walk; a Trim Shop cell is its own unit-group). `FoundFamily` = `ufn_AreaFamily(CellLocationId)`.
  - `ChargeFamily` = `ufn_RejectChargeFamily(DefectCodeId, FoundFamily)`.
  - `UnitLocationId` = `FoundAtLocationId` when `ChargeFamily = FoundFamily`, else NULL. `IsFoundDownstream = 1` when both families are known and differ, **or** there is no cell but `ChargeFamily` is known (spec 6.4, no-cell rule).
  - Rows with `ChargeFamily` NULL (Non-Specific, no cell) are returned with `IsFoundDownstream = 0` and `UnitLocationId` NULL, so the procs can count them for the footnote.

- [ ] **Step 1: Write tests**: `[Good] DC press sums PieceDelta for the shift only`; `[Good] trim checkpoint credit = count minus previous checkpoint`; `[Good] trim rework pass (ShiftId NULL) excluded`; `[Good] M&A FG counted on the line`; `[Good] Received-origin FG excluded`; `[Scrap] DC defect at press -> on press`; `[Scrap] DC defect found on M&A line -> UnitLocationId NULL, ChargeFamily diecast, IsFoundDownstream 1`; `[Scrap] DieMaintenance at press -> on press`; `[Scrap] MppNonSpecific on line -> on line`; `[Scrap] no-cell DC reject -> diecast, found downstream, plant shift by RecordedAt`; `[Scrap] no-cell Non-Specific -> ChargeFamily NULL`; `[Scrap] cell outside any unit, DC-charged -> Die Cast area level`; `[Scrap] ShiftId NULL row placed by RecordedAt`; `[Scrap] non-reject scrap flagged IsNonReject 1`.
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** -> PASS. **Step 5: Commit.**

### Task 6: `Oee.Dashboard_GetUnitSummary` (spec 6.3, 8)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_Dashboard_GetUnitSummary.sql`
- Test: `sql/tests/0117_Oee_Dashboard/050_unit_summary.sql`

**Interfaces:** `Oee.Dashboard_GetUnitSummary @Zoom NVARCHAR(5), @AnchorShiftId BIGINT, @AreaFamily NVARCHAR(10) = NULL` returns one result set with a `RowKind` column:

| RowKind | Meaning |
|---|---|
| `Unit` | one per unit (press / trim press / line) |
| `Station` | one per OEE-enabled station under a line (availability + downtime only) |
| `Group` | one per ProductionArea (Die Cast 1-4, Trim Shop 1-2, M&A 1-2). For Trim, quality is the shop's |
| `Area` | one per family (`diecast` / `trim` / `ma`), including found-downstream and no-cell scrap |
| `Plant` | one row |

Columns: `RowKind, AreaFamily, ProductionAreaId, ProductionAreaName, LocationId, LocationCode, LocationName, ParentLocationId, BaseMinutes, UnplannedMinutes, PlannedMinutes, Availability DECIMAL(5,4) NULL, AvailabilityBand, Good, Scrap, NonRejectScrap, FoundDownstreamScrap, UnplacedScrap, Quality DECIMAL(5,4) NULL, QualityBand, NoReasonCount, NoReasonMinutes, DowntimeMinutes, LastToolCode NULL, HasProduction BIT, IncludesInProgressShift BIT`.
- Trim press `Unit` rows carry `Good`/`Scrap`/`Quality` NULL (D5).
- A unit with no production and no downtime -> `HasProduction = 0` and `Availability` NULL (5.3).
- No-reason = `DowntimeEvent.DowntimeReasonCodeId IS NULL` within the period's shifts, counted as unplanned.

- [ ] **Step 1: Write tests**: `[Summary] pooled not averaged` (a 2-hour unit at 50% + an 8-hour unit at 100% -> area 0.9000, not 0.7500); `[Summary] roll-up line pools effective minutes` (line availability = station mean; area uses Base * (1-mean)); `[Summary] no-production unit -> HasProduction 0, Availability NULL`; `[Summary] NULL-reason event -> NoReasonCount 1 and counted unplanned`; `[Summary] trim scrap on shop Group, trim press Unit quality NULL`; `[Summary] DC-charged found on line -> in diecast Area Scrap and FoundDownstreamScrap, not in line Unit, not in any Group`; `[Summary] Week zoom = sum of its Day rows` (minutes and counts); `[Summary] two dies -> latest only, one row`; `[Summary] unknown anchor -> 0 rows`; `[Summary] @AreaFamily filter keeps only that family plus Plant`.
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement** by iterating `ufn_ShiftsForPeriod` and `CROSS APPLY`-ing `ufn_ShiftAvailability`, `ufn_ShiftGood` and `ufn_ShiftScrap` per shift, then aggregating per RowKind. **Step 4: Run** -> PASS. **Step 5: Commit.**

### Task 7: Benchmark gate + period navigation (spec 6.1, 5.1)

**Files:**
- Create: `sql/scratch/2026-10-29_oee_dashboard_benchmark.sql` (fixture generator + timing; never touches `MPP_MES_Dev`: `USE MPP_MES_Test` at the top, per memory `feedback_scratch_scripts_hardcode_dev`)
- Create: `sql/migrations/repeatable/R__Oee_Dashboard_GetPeriod.sql`
- Test: `sql/tests/0117_Oee_Dashboard/060_period.sql`

**Interfaces:** `Oee.Dashboard_GetPeriod @Zoom NVARCHAR(5), @AnchorShiftId BIGINT = NULL, @Step INT = 0` -> one row: `AnchorShiftId, Zoom, PeriodLabel` (e.g. `N'2nd shift - Tue 10/27'`, `N'Production day Tue 10/27'`, `N'Week of Mon 10/26'`), `IsInProgress BIT`, `HasNext BIT`. NULL anchor = the last **ended** shift (`ActualEnd IS NOT NULL`, latest). `@Step` of -1/+1 moves one shift, day or week. Stepping past the open shift is refused (`HasNext = 0`).

- [ ] **Step 1: Benchmark.** Generate one realistic month on `MPP_MES_Test`: every seeded OEE unit, 3 shifts/day, ~6 downtime events per unit-shift, DC contributions, trim checkpoints, FG LOTs and ~2% rejects. Time `EXEC Oee.Dashboard_GetUnitSummary N'Week', @anchor` (cold and warm, `STATISTICS TIME`). **Gate: under 2 s warm.** If it misses, stop and report the numbers to Jacques; a per-shift cache is his decision (spec 6.1), not the builder's.
- [ ] **Step 2: Write period tests**: `[Period] default anchor is last ENDED shift`; `[Period] Step -1 at Day moves to the previous production day's last shift`; `[Period] Step +1 onto the open shift -> IsInProgress 1`; `[Period] Step +1 from the open shift -> HasNext 0, anchor unchanged`; `[Period] labels as above`.
- [ ] **Step 3: Run** -> FAIL. **Step 4: Implement.** **Step 5: Run** -> PASS. **Step 6: Commit** the benchmark script (unarmed) + proc + test, with the timing in the message.

### Task 8: Remaining read procs (spec 8)

**Files:**
- Create: `R__Oee_Dashboard_GetTrend.sql`, `R__Oee_Dashboard_GetDowntimeByReason.sql`, `R__Oee_Dashboard_GetScrap.sql`, `R__Oee_Dashboard_GetBreakdown.sql`, `R__Oee_Dashboard_GetDowntimeEntries.sql` (all in `sql/migrations/repeatable/`)
- Test: `sql/tests/0117_Oee_Dashboard/070_read_procs.sql`

**Interfaces:**
- `Oee.Dashboard_GetTrend @AnchorShiftId, @AreaFamily = NULL, @LocationId = NULL` -> 7 rows `(ProductionDay, DayLabel, Availability, Quality, AvailabilityBand)`, ending at the anchor's production day; a day with no data -> NULLs (the row is still present).
- `Oee.Dashboard_GetDowntimeByReason @Zoom, @AnchorShiftId, @AreaFamily = NULL, @LocationId = NULL` -> `(ReasonCodeId NULL, ReasonCode, ReasonDescription, ReasonTypeName, IsPlanned BIT, IsNoReason BIT, Minutes, EventCount)`, Pareto order. `@LocationId` includes the unit's stations.
- `Oee.Dashboard_GetScrap @Zoom, @AnchorShiftId, @AreaFamily = NULL, @LocationId = NULL, @GroupBy NVARCHAR(10)` with `@GroupBy` in `N'Defect' | N'Part' | N'Line'` -> `(GroupKey, DefectCode NULL, DefectDescription NULL, ItemId NULL, PartNumber NULL, LocationId NULL, LocationName NULL, Good NULL, Quantity, IsNonReject, IsFoundDownstream, ChargedToFamily, FoundAtLocationName NULL, Quality NULL)`. With `@LocationId` it returns that unit's charged scrap **plus** the found-here-charged-elsewhere rows with `IsFoundDownstream = 1` (shown greyed, 5.4). With `@AreaFamily` it returns the area's unit scrap plus its found-downstream rows.
- `Oee.Dashboard_GetBreakdown @Zoom, @AnchorShiftId, @LocationId` -> Day: 3 rows (3rd, 1st, 2nd); Week: 7 rows. Columns `(ChildZoom, ChildAnchorShiftId, Label, BaseMinutes, DowntimeMinutes, Availability, Good, Scrap, Quality, Bands)`. Shift zoom -> 0 rows.
- `Oee.Dashboard_GetDowntimeEntries @AnchorShiftId, @LocationId` -> `(DowntimeEventId, LocationId, LocationName, IsStation, Minutes, IsApproximate, ReasonCode NULL, ReasonTypeName NULL, IsPlanned, ByInitials, StartedAtEt)`. First check whether `Oee.DowntimeEvent_GetByScope` already returns this; if it does, use it and skip the new proc.

- [ ] **Step 1: Write tests**, one per proc minimum: `[Trend] 7 rows, gap day NULL`; `[Reason] NULL reason as its own IsNoReason row`; `[Reason] station entries included for a line`; `[Scrap] Part grouping for a trim shop gives per-part quality`; `[Scrap] Line grouping lists each M&A line with its top defect`; `[Scrap] unit view shows found-here-charged-to-DC greyed (IsFoundDownstream 1) and excludes it from Quality`; `[Breakdown] Day order 3rd,1st,2nd`; `[Entries] Approximate flag passes through`.
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** the whole suite: `.\sql\tests\Run-Tests.ps1`. Expected: 0 failures, **and** an assertion count equal to the baseline plus the new ones (memory `feedback_runtests_exit1_zero_failures`). **Step 5: Commit.**

### Task 9: Core named queries + `BlueRidge.Oee.Dashboard`

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/oee/Dashboard_GetUnitSummary/{query.sql,resource.json}` and the same for `Dashboard_GetPeriod`, `_GetTrend`, `_GetDowntimeByReason`, `_GetScrap`, `_GetBreakdown`, `_GetDowntimeEntries` (copy `resource.json` shape from `oee/DowntimeEvent_GetByScope`; `type: Query`; `@Zoom`/`@AreaFamily`/`@GroupBy` `sqlType: 7`, ids `sqlType: 8` BIGINT -- match what the sibling NQs use)
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Dashboard/{code.py,resource.json}`

**Interfaces** (module `BlueRidge.Oee.Dashboard`; each returns a list of dicts, or a dict for `period`, and never `None`):
`period(zoom, anchorShiftId, step)`, `unitSummary(zoom, anchorShiftId, areaFamily)`, `trend(anchorShiftId, areaFamily, locationId)`, `downtimeByReason(zoom, anchorShiftId, areaFamily, locationId)`, `scrap(zoom, anchorShiftId, areaFamily, locationId, groupBy)`, `breakdown(zoom, anchorShiftId, locationId)`, `downtimeEntries(anchorShiftId, locationId)`. On an empty result or an exception (caught with `except (Exception, java.lang.Exception)`), `period` returns `_EMPTY_PERIOD` (every key, `None`/`""`/`False`) and the list functions return `[]`. No arithmetic, no thresholds in Python.

- [ ] **Step 1:** Write the NQs and the module. **Step 2:** `.\scan.ps1`. **Step 3: Verify** in the Script Console (or the gateway's script test path): `BlueRidge.Oee.Dashboard.unitSummary('Day', None, None)` returns rows on `MPP_MES_Dev`, and `period('Day', -1, 0)` returns `_EMPTY_PERIOD`. **Step 4: Commit.**

### Task 10: Shared components + Site page (spec 5.1, 5.2; mockup 1)

**Files:**
- Create under `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Oee/`: `Gauge`, `FutureCard`, `KpiCard`, `PeriodHeader`, `TrendBars`, `AreaCard` (each its own sibling folder with `view.json` + `resource.json`)
- Create: `.../views/BlueRidge/Views/ShopFloor/Oee/Site/{view.json,resource.json}`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json` (route `/shop-floor/oee`)

**Interfaces:**
- `Gauge` params: `value` (0-1 or null), `band` (`green|amber|red|null`), `label`. An SVG arc per the mockup 3 markup; null -> "--".
- `FutureCard` params: `title`. Darkened "Coming in a future deployment".
- `PeriodHeader` params: `title`, `breadcrumb` (list of `{label, path}`), `zoom`, `anchorShiftId`. It owns the Shift/Day/Week control and the `‹ ›` stepping, calls `Dashboard.period` and broadcasts `oeePeriodChanged {zoom, anchorShiftId}` (page scope). It shows the in-progress note when `IsInProgress`.
- The page keeps `view.custom.period = {zoom:'Shift', anchorShiftId:null, label:'', isInProgress:false, hasNext:false}`, all pre-declared.

- [ ] **Step 1:** Build the components and the Site view, matching mockup 1: a KPI row (Plant availability, Plant quality, Downtime with no reason, Performance future, OEE future); three `AreaCard`s, each with gauges, downtime min, no-reason count, scrap count, an "incl. N found downstream" line when non-zero, the 3 worst units with each one's top unplanned reason, and a 7-bar trend. A tap opens `/shop-floor/oee/area/<family>`. **Step 2:** `.\scan.ps1`. **Step 3: Verify** in the browser pane: `/shop-floor/oee` loads on the last completed shift with no Component Error, `‹` / `›` step, and Day/Week regroup. Screenshot it. **Step 4: Commit.**

### Task 11: Area page (spec 5.3; mockup 2)

**Files:**
- Create under `Components/Oee/`: `UnitTile`, `GroupHeader`, `ParetoBars`, `ScrapTable`
- Create: `Views/ShopFloor/Oee/Area/{view.json,resource.json}`; route `/shop-floor/oee/area/:areaKey` in page config

- [ ] **Step 1:** Build it to mockup 2 layout "A":
  - Groups per ProductionArea with header availability and quality.
  - Die Cast tiles show the die (`LastToolCode`).
  - Trim tiles show availability and downtime only, plus a per-shop "shop scrap by part" table (`GroupBy='Part'`).
  - M&A tiles list station availabilities.
  - The right column holds `ParetoBars` (unplanned red, planned grey, no-reason amber) and scrap: by defect + part for diecast/trim, by line for ma. A **"Found downstream"** row appears when present.
  - Dimmed "No production" tiles; a red border + "no reason" tag. A tile tap opens `/shop-floor/oee/unit/<id>`.
  - An unknown `areaKey` shows "Unknown area" with a link back.
- [ ] **Step 2:** `.\scan.ps1`. **Step 3: Verify** all three area keys and a bogus key in the browser pane; screenshot. **Step 4: Commit.**

### Task 12: Unit drill-down (spec 5.4; mockup 3 "v5")

**Files:**
- Create: `Views/ShopFloor/Oee/Unit/{view.json,resource.json}`; route `/shop-floor/oee/unit/:locationId`
- Create under `Components/Oee/`: `StationStrip`, `DowntimeEntryRow`

- [ ] **Step 1:** Build it to mockup 3:
  - Availability and Quality gauges, a Downtime minutes card, and Performance/OEE future cards.
  - At Day/Week zoom, a breakdown table (a row tap zooms in one level); at Shift zoom, the downtime entries.
  - Three side-by-side panels: Pareto (reason/type toggle), scrap by defect (non-reject and charged-elsewhere rows greyed, the latter tagged "charged to <family>"), and downtime entries (`~` on approximate).
  - **Edit** opens the existing `Popups/DowntimeEditor` and refreshes on close.
  - Trim press: the Quality gauge is replaced by a "Shop level -- <shop> <q>% ›" link card.
  - M&A line: a station strip.
  - Die Cast press: a found-downstream footnote.
  - Footnote on no-cell / unplaced scrap.
- [ ] **Step 2:** `.\scan.ps1`. **Step 3: Verify** one press, one trim press and one line, plus Edit -> popup -> close -> refresh, in the browser pane; screenshot. **Step 4: Commit.**

### Task 13: Supervisor Dashboard tile + "OEE Summary" report (spec 5.5, 5.6)

**Files:**
- Modify: `.../views/BlueRidge/Views/ShopFloor/SupervisorDashboard/view.json` (the stub "Shift Availability" tile, ~line 289; file edits are permitted for this work)
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Reports/code.py` (`registry()` entry `oee_summary`)
- Create: the report resource via the global `ignition-reporting` skill (read `ignition-context-pack/10_reporting_module.md` first)
- Possibly modify: the Reports landing page, if it has no way to pick a zoom (see Step 2)

- [ ] **Step 1:** The tile shows plant availability for the last completed shift (`unitSummary('Shift', None, None)` Plant row) with its band, and opens `/shop-floor/oee`.
- [ ] **Step 2:** Registry entry: `{"key": "oee_summary", "title": "OEE Summary", "desc": "Availability, downtime and quality by area and unit for a shift, day or week.", "project": "MPP", "reportPath": "OEE Summary", "available": True, "params": [{"id": "ShiftId", "label": "Shift", "kind": "shift", "required": True}, {"id": "Zoom", "label": "Period", "kind": "choice", "options": ["Shift", "Day", "Week"], "required": True}]}`. The registry has no `choice` kind today (`dateRange`, `shift`, `lot`, `controlledRun`), so add `choice` to the landing page's parameter renderer as a dropdown.
- [ ] **Step 3:** The report's SQL calls `Oee.Dashboard_GetUnitSummary` and `Oee.Dashboard_GetDowntimeByReason`, giving per area: unit, availability, unplanned/planned min, good, scrap, quality %, top reasons. Render-verify per the skill.
- [ ] **Step 4: Verify** the tile and the report from `/shop-floor/reports` in the browser pane. **Step 5: Commit** (check `git diff --stat` for pickled live data, memory `feedback_designer_pickles_live_data`).

### Task 14: Docs + status

**Files:** `MPP_MES_DATA_MODEL.md` (Oee section: new functions/procs and the counting + charge rules), `PROJECT_STATUS.md` (OEE entry -> built), the spec's revision table (v1.0 = built), `notes/2026-10-28_handoff-oee-dashboard.md` (closed). The FDS is untouched (memory `feedback_fds_is_plan_not_state`). Regenerate `.docx` for any doc that has one (CLAUDE.md "Doc generation").

- [ ] **Step 1:** Write the doc changes. **Step 2: Commit.**
