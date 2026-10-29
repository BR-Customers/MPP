# OEE Dashboard -- Availability and Quality, Site to Unit

**Date:** 2026-10-27
**Status:** Approved by Jacques 2026-10-29 (v0.2)
**Mockups:** `docs/superpowers/specs/2026-10-27-oee-dashboard-mockups/` (open in a browser; the dark-navy frames are the screens, the text around them is commentary)

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-10-27 | First draft from the brainstorm with Jacques. |
| 0.2 | 2026-10-29 | Jacques answered the four open questions (Section 11). Scrap is charged by defect code at area level (6.4); production day runs 3rd -> 1st -> 2nd (6.6); FG-only M&A good confirmed; no change order -- everything ships. |

---

## 1. Why

The OEE schema exists and operators already feed it: downtime is captured on every shift through the Downtime Entry and End-of-Shift screens, shifts run on the `ShiftBoundaryTicker`, and good and scrap counts are recorded at Die Cast, Trim and Machining & Assembly. `Oee.Shift_GetAvailability` already computes availability per OEE-enabled unit per shift. **Nobody can see any of it.** No view calls the availability proc, and the Supervisor Dashboard's "Shift Availability" tile is a stub.

This feature puts what the plant already records in front of supervisors and managers: how much of each shift each press, trim press and line was available, how much of what it made was good, and why it stopped. The answer has to be trustworthy enough to act on, so it shows only what the data can honestly support.

## 2. Goals, non-goals, anti-goals

**Goals**

- G1. A **site screen** with one card per production area (Die Cast, Trim, Machining & Assembly) showing availability, quality, downtime and the worst units.
- G2. An **area screen** for each of the three, with a tile per unit grouped by the real plant areas (Die Cast 1-4, Trim Shop 1-2, M&A 1-2).
- G3. A **unit drill-down** for any press, trim press or line: availability and quality gauges, downtime by reason, scrap by defect, the downtime entries themselves with an Edit link.
- G4. **Shift / Day / Week zoom** with previous/next stepping on all three levels.
- G5. **Performance and OEE shown as darkened "Coming in a future deployment" cards** on every level so the shape of the finished product is visible without implying numbers that do not exist.
- G6. Fix the two scrap writers that drop shift and line, so M&A quality is not empty.

**Non-goals (this deployment)**

- Performance and OEE numbers. They need ideal cycle times (Section 9).
- Any timeline / Gantt of downtime. Downtime is entered at shift end as durations; clock positions would be fiction.
- PLC-sourced downtime. `DowntimePlcWatcher` is not commissioned (`_WATCH = []`) and there is no Tag Historian.
- `Oee.OeeSnapshot` or any stored roll-up. Everything is computed on read.
- Changing how operators record scrap. No new pickers, no per-machine scrap at Trim, no per-side scrap on M&A lines.

**Anti-goals** -- it fails even if it works if:

- It shows a live current-shift number that reads ~100% because nobody has entered downtime yet.
- Area or plant figures average percentages, so a press that ran 2 hours weighs as much as one that ran 8.
- It forces a workflow change operators have refused (live downtime entry, scrap side selection).
- It invents precision: a trim press "quality" figure when trim scrap is only known by shop.

## 3. Constraints

- **Scope.** `reference/MPP_Scope_Matrix.xlsx` rows 16 (OEE) and 18 (KPIs) read "Not Included"; FDS-09-011 tags OEE FUTURE. Row 17 (Downtime) and FDS 9.4 (shift availability, MVP) are in. **Jacques, 2026-10-29: no change order.** Availability, downtime and quality are built and shipped now. The plant already records good and bad parts, and showing two of OEE's three factors has clear precedent. Only Performance and OEE stay as future cards (Section 11, Q4).
- **Downtime is entered at end of shift**, by operators who will not change that. Figures for a shift are only complete once its end-of-shift entry is done.
- **SQL conventions** from CLAUDE.md: read procs return one result set, no OUTPUT parameters, timestamps stored UTC and displayed ET, business rules in SQL not Python, `EXEC` parameters literal or `@variable`.
- **INSERT-EXEC cannot nest.** Tests capture procs with INSERT-EXEC, so a new read proc cannot itself INSERT-EXEC `Oee.Shift_GetAvailability`. The availability calculation must be shared through a function (Section 6.1).
- **Ignition**: all named queries in Core; new views in MPP; new view folders need `view.json` + `resource.json`; run `scan.ps1` after adding resources. File edits to existing views are permitted for this work (Jacques, 2026-10-27).
- **Shared Dev DB and gateway.** Do not reset `MPP_MES_Dev`; validate on a throwaway `MPP_MES_Test`.

## 4. The decisions (Jacques's)

| # | Decision |
|---|---|
| D1 | Build now: Availability, downtime, shifts, Quality (good vs scrap). Performance and OEE are darkened future cards. |
| D2 | Performance, when it comes, uses an ideal cycle time **per die or cast part** -- "that's as good as it gets". |
| D3 | On M&A the **line** is the OEE unit. Its stations (Machining, Assembly Conveyor A/B, ...) contribute **downtime only**. Line availability is the mean of its OEE-enabled stations -- which is what `Shift_GetAvailability` v2.0 already does. |
| D4 | The `IsOeeEnabled` flag ("OEE / downtime enabled" in the Plant Hierarchy editor) decides which locations are units. Already how `DowntimeScope_ListForTerminal` and `Shift_GetAvailability` work; no change. |
| D5 | **Trim scrap stays at shop (area) level.** The part is known (`RejectEvent.ItemId`), which is enough. Trim press tiles carry availability only; quality lives on the shop, broken out by part. |
| D6 | **M&A scrap stays at line level.** No side picker. "No need to force something operators and staff are not ready to integrate." |
| D7 | No timeline anywhere. Zoom is Shift -> Day -> Week. |
| D8 | Site screen = one card per area (mockup 1). Area screens = tiles by sub-area (mockup 2, layout "A"). Drill-down = mockup 3 ("v5"): gauges for Availability and Quality with no subtext, the three lower panels side by side, larger text. |
| D9 | Area-page tiles show the **die** a press ran (not the part); the M&A scrap panel lists scrap **by line**. |
| D10 | The Machining OUT mint scrap row gets a shift stamp. Scrap recorded before the fix counts against the line with no backfill. |
| D11 | **Scrap is charged by defect code, at area level** -- matching `Quality.Reject_GetPlantSummary`. A die-cast defect found on an M&A line counts against Die Cast, not the line, and lands on the Die Cast area/site figures, not on any press (6.4). |
| D12 | Die Maintenance-charged scrap counts against Die Cast. Non-Specific MPP / Non-Specific Supplier scrap counts where it was found (6.4). |
| D13 | **Production day runs 3rd -> 1st -> 2nd.** The 3rd shift starting Monday 22:30 belongs to Tuesday (6.6). |
| D14 | M&A good stays Manufactured FinishedGood LOTs only: no MPP line ends in a SubAssembly. |
| D15 | No change order. Everything in this spec ships now, including the Supervisor Dashboard tile and the PDF report. The pages are named "OEE" (`/shop-floor/oee`). |

## 5. The screens

All three share one header: breadcrumb, title, the **Shift / Day / Week** segmented control, `‹ [period] ›` stepping, and a note when the period includes the shift in progress. All numbers display ET.

### 5.1 Defaults and the current shift (my call)

The site screen opens on the **last completed shift**, not the current one. A shift in progress is reachable with `›` and is labelled "in progress -- downtime not yet entered". Day zoom defaults to the production day containing that shift; Week to the week containing it.

"Open downtime" is replaced everywhere by **"Downtime with no reason"** (count + minutes): with end-of-shift entry there is rarely anything open, but entries saved without a reason are the actual data-quality gap, and they count as unplanned.

### 5.2 Site screen (mockup 1) -- new page `/shop-floor/oee`

- KPI row: Plant availability, Plant quality, Downtime with no reason, Performance (future), OEE (future).
- Three area cards, each: Availability gauge, Quality gauge, downtime minutes, no-reason count, scrap count, the three lowest-availability units with each unit's largest unplanned downtime reason, and a 7-bar availability trend (last 7 production days ending at the selected period). Tap -> area screen.
- An area card's "units" are presses (Die Cast), trim presses (Trim), and **lines** (M&A -- not stations).
- An area card's quality and scrap count include scrap **charged to that area but found downstream** (6.4). When it is non-zero the card shows a small "incl. N found downstream" line under the scrap count.

### 5.3 Area screens (mockup 2) -- new page `/shop-floor/oee/area/:areaKey`

`areaKey` is `diecast`, `trim` or `ma` (my call: these three "areas" are groupings of ISA-95 ProductionAreas, not locations; see 6.2).

- Same KPI row, scoped to the area.
- Groups per ProductionArea (Die Cast 1-4, Trim Shop 1-2, M&A 1-2), each with its own availability and quality in the header.
- Right column: downtime by reason (unplanned in red, planned in grey, no-reason in amber) and scrap.
- **Die Cast tile:** availability, quality, downtime minutes, the die (Tool code) it ran -- the latest-used die in the period when it ran more than one.
- **Trim tile:** availability and downtime only. Each Trim Shop group carries a **"shop scrap by part"** table (part, top defect, good, scrap, quality %). Right panel: scrap by defect + part.
- **M&A tile:** the line's availability, quality, good/scrap; when the line has OEE-enabled stations, each station's availability is listed inside the tile. Right panel: **scrap by line** with each line's top defect.
- **A tile with no production and no downtime in the period is dimmed** and reads "No production", availability "--" (my call -- otherwise an idle press reports 100%).
- **A red border + "no reason" tag** when the unit has a downtime entry with no reason.
- **Found downstream.** Scrap charged to this area but recorded in another area (6.4) cannot be placed on a press, trim shop or line. It appears as its own **"Found downstream"** row in the right-hand scrap panel (by defect + part + where found). It is included in the area KPI row's quality but in no group header or tile.
- Tile colour bands: see 6.5.

### 5.4 Unit drill-down (mockup 3) -- new page `/shop-floor/oee/unit/:locationId`

- Gauges: Availability, Quality (no subtext). Plain card: Downtime minutes. Future cards: Performance, OEE.
- **Breakdown table** -- at Day zoom the day's three shifts (3rd -> 1st -> 2nd); at Week zoom the seven days; each row zooms in one level on tap. At Shift zoom it is replaced by the downtime entries.
- One row of three panels: Downtime by reason (Pareto, reason / type toggle), Scrap by defect (defect, part, qty; non-reject scrap shown greyed and excluded), Downtime entries (Min / Reason / Type / By / Edit). Durations show `~` when `IsApproximate`.
- **Edit** opens the existing `Popups/DowntimeEditor` (already elevation-gated). On close, the page refreshes.
- **Trim press drill-down:** the Quality gauge is replaced by a link card "Shop level -- Trim Shop 1 96.8% ›" that opens the area screen scrolled to that shop. Scrap panel shows the shop's scrap.
- **M&A line drill-down:** adds a station strip under the KPI row (each OEE-enabled station's availability + downtime minutes). Downtime entries and Pareto include station-level entries, labelled with the station.
- **Scrap found here but charged elsewhere** (e.g. a "DC - Broken Gate" scrapped on an M&A line) is listed in the scrap panel greyed, tagged "charged to Die Cast", and excluded from this unit's quality, the same treatment as non-reject scrap. A Die Cast press drill-down carries a footnote with the Die Cast area's found-downstream count, since that scrap is not traced to a press.

### 5.5 Entry points

- Supervisor Dashboard: the stub "Shift Availability" tile becomes a live tile (plant availability, last completed shift) that opens `/shop-floor/oee`.
- `/shop-floor/reports`: one new report (5.6).
- No Config Tool changes.

### 5.6 Report (my call)

One Reporting Module PDF, **"OEE Summary"**, registry key `oee_summary`, parameters zoom + period: the area screen's tables for all three areas in print form (unit, availability, unplanned/planned minutes, good, scrap, quality %, top reasons). Built with the global `ignition-reporting` skill, report SQL calling the same read procs.

## 6. How the numbers are computed

### 6.1 Availability -- reuse, don't rewrite

The per-shift calculation in `Oee.Shift_GetAvailability` v2.0.1 is the authority (schedule-based planned time, overrides, time-overlap downtime matching, one-minute grid, planned = `IsExcused`, ancestor inheritance, mean roll-up). It has to become a table-valued function **`Oee.ufn_ShiftAvailability(@ShiftId)`** returning the same columns, and the proc reduces to `SELECT ... FROM Oee.ufn_ShiftAvailability(@ShiftId) WHERE @LocationId IS NULL OR LocationId = @LocationId`. Its existing tests must pass unchanged. All new procs read the function.

**This is a rewrite, not a move.** The proc is built on `#temp` tables, `UPDATE`s and a `WHILE` loop (`R__Oee_Shift_GetAvailability.sql` ~111-332), none of which a function allows. It becomes a multi-statement TVF on table variables, or (better if it can be done) a set-based inline TVF. Table variables carry no statistics, and Week zoom calls it ~21 times per request, and the 7-day trend calls it for ~21 shifts too. **Benchmark first:** before any view work, time a Week-zoom `Dashboard_GetUnitSummary` across the whole plant on a DB holding a realistic month of downtime. Target: under 2 s. If it misses, that is the trigger to revisit a per-shift cache (the non-goal in Section 2 is "not this deployment unless the benchmark forces it", and the builder raises it rather than deciding it).

### 6.2 Units and areas

- A **unit** is an OEE-enabled location with no OEE-enabled ancestor, plus (for drill-down/station strips) its OEE-enabled descendants.
- **Area grouping** (site cards / area pages) is by the unit's ProductionArea ancestor, then by area family. Family is derived from the ProductionArea's definition / the units' type (DieCastMachine -> Die Cast, TrimPress -> Trim, ProductionLine -> M&A). The builder picks the cleanest existing discriminator; it lives in SQL (one function, e.g. `Oee.ufn_AreaFamily`), never in Python.

### 6.3 Aggregation across shifts, units and areas -- pooled, never averaged

For any set of (unit, shift) pairs:

```
Availability = SUM(BaseMinutes - UnplannedMinutes) / SUM(BaseMinutes)
Quality      = SUM(Good) / SUM(Good + Scrap)          -- non-reject scrap excluded
```

At area and site level, `Scrap` also includes that area's found-downstream and no-cell rejects (6.4). At unit and ProductionArea-group level it does not.

A **roll-up unit** (a line with stations) contributes its own `BaseMinutes` and an *effective* unplanned figure `BaseMinutes * (1 - Availability)`, where Availability is its station mean for that shift. That keeps the line's own number exactly what `Shift_GetAvailability` reports while letting it pool into area totals by its run time.

Units with `BaseMinutes = 0` are excluded from availability (NULL, shown "--").

### 6.4 Good and scrap counts

Good-count rules are the ones already agreed for `Quality.Reject_GetPlantSummary` (Jacques, 2026-08-25), narrowed to a unit and shift:

| Area | Good | Unit it lands on | Shift |
|---|---|---|---|
| Die Cast | `SUM(Workorder.DieCastContribution.PieceDelta)` | `CellLocationId` (the press) | `ShiftId` |
| Trim | **per-shift checkpoint credit**: each trim `ProductionEvent` (partial checkpoint via `TrimPartial_Record`, and the closing `TrimOut`) is credited with its count minus the LOT's previous trim checkpoint -- the rule `TrimPartial_Record` already defines, via `Workorder.ufn_TrimPassPreviousCount` | the Trim Shop above `ProductionEvent.TerminalLocationId` | `ProductionEvent.ShiftId`; rows with `ShiftId NULL` (rework passes) are not shift production and are excluded |
| M&A | `PieceCount` of **Manufactured**-origin FinishedGood LOTs | the line above `Lot.CreatedAtTerminalId` | shift window containing `Lot.CreatedAt` |

The M&A rule tightens the plant-summary rule in one way: pass-through repack trays are minted as `Manufactured` LOTs, but the **Received**-origin LOTs they consume are excluded, so a part received finished is not counted twice. (The plant summary counts every FinishedGood LOT; the builder should check and note whether that proc double-counts received FG, as a side observation, not a fix.)

**Scrap** = `Workorder.RejectEvent` rows whose defect code is not `IsNonRejectScrap`. **It is charged by defect code** (D11), the rule `Quality.Reject_GetPlantSummary` uses, so the dashboard and the reject report agree on which area owns a piece of scrap.

**Step 1 -- charge family.** Each reject gets a *charge family* from `DefectCode.ChargeToPartyId`:

| ChargeToParty | Charge family |
|---|---|
| `DieCast`, `DieMaintenance` (D12) | Die Cast |
| `TrimShop` | Trim |
| `MachineShop` | M&A |
| `MppNonSpecific`, `SupplierNonSpecific` (D12) | the family of the unit where it was recorded ("where found") |

The mapping lives in SQL (one function, e.g. `Oee.ufn_RejectChargeFamily`), never in Python.

**Step 2 -- where it lands.** The *recording unit* is the one the row's `CellLocationId` gives:

- Die Cast: `CellLocationId` = press.
- Trim: `CellLocationId` = the Trim Shop (as `TrimOut_Record` / `TrimPartial_Record` write it today). Per-part breakdown via `RejectEvent.ItemId`.
- M&A: `CellLocationId` = the line.

If the charge family **matches** the recording unit's family, the reject lands on that unit: press, trim shop or line, exactly as before. If it **differs** (a DC-charged defect found on an M&A line or at Trim; a Trim-charged defect found on an M&A line), it is **found downstream**. It counts in the charge family's **area and site** quality only, on no unit and in no ProductionArea group, because the dashboard does not trace the LOT back to its press. The recording unit shows it greyed and excludes it (5.4).

- **Shift fallback:** a reject row with `ShiftId IS NULL` is assigned by `RecordedAt` falling in the shift window (my call -- covers rows written before G6 without a backfill).
- **Rejects with no `CellLocationId`** (Hold/LotDetail, ContainerRework, Controlled Run): when the charge family is Die Cast, Trim or M&A they count at that **area** level, the same as found-downstream scrap, placed in a shift by `RecordedAt` against the plant shift (`Oee.Shift`) (my call -- this matches the Plant Summary, which counts them). Non-Specific rejects with no cell have no "where found" and are left out of dashboard quality, with a footnote. The existing reject reports still show them.

### 6.5 Colour bands (placeholder)

Green >= 85 %, amber >= 70 %, red below, for availability and quality alike, returned by SQL (`Oee.ufn_OeeBand(@Ratio)`) so the thresholds live in one place. MPP may supply real thresholds later.

### 6.6 Production day and week (D13)

The production day runs **3rd -> 1st -> 2nd**: the 3rd shift that starts Monday 22:30 is the first shift of Tuesday's production day.

- **Production day of a shift = the Eastern calendar date its window ends.** That gives the rule without naming shifts: the 1st and 2nd shifts end on the date they start, and the 3rd ends the next morning. One SQL function (e.g. `Oee.ufn_ProductionDay(@ShiftId)`) owns it.
- **Production week = Monday-Sunday production days**, so a week starts with the 3rd shift beginning Sunday 22:30.
- **The existing `BusinessDate` is not changed.** In `Shift_GetAvailability`, `ufn_ShiftWindowForLocation` and the shift-override procs/screens, `BusinessDate` is the calendar date a shift *starts*. It is the key that schedule windows and overrides are looked up by, not a reporting day. Renumbering it would reach the override editor and its stored rows, and the dashboard does not need that. The dashboard groups by production day only. Its Day/Week labels say "Production day Tue 10/27" so the two dates are not confused.
- An override that stretches a shift past its normal end can move that shift's end date. The function uses the *scheduled* window end, so an override never moves a shift into another production day (my call).

## 7. Writer fixes (G6)

1. **`Workorder.RejectEvent_RecordByPartFifo`** (the Scrap Entry popup on Assembly and Machining terminals) inserts `NULL` for `ShiftId` and `CellLocationId`. It already knows the line: `@LocationId` is where it finds the LOTs. Write `CellLocationId = @LocationId` and `ShiftId = (SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@LocationId, <now>))` -- it is an inline TVF keyed on location because overrides make the answer per-equipment; call it the way `TrimOut_Record` does (~377). No signature change; no popup change. *Without this, almost all M&A scrap is invisible to the dashboard* (my call -- it follows D6, and the scrap stays line-level).
2. **`Workorder.MachiningOut_Mint`** writes `CellLocationId` = the LOT's line but no `ShiftId`. Add `ShiftId` from `Oee.ufn_ShiftIdForInstant(<the line>, <now>)`, same call shape (D10).
3. No backfill. The time-window fallback in 6.4 covers older rows that have a cell.

Both are repeatable-proc changes with version bumps and change-log lines; each gets a test asserting the new columns. `Oee.ShiftOverride_Restamp` deliberately ignores reject rows and stays that way.

## 8. Build shape

**SQL** (repeatable procs, `Oee` schema; versioned migration only if the builder needs a new object that cannot be repeatable):

| Object | Purpose |
|---|---|
| `Oee.ufn_ShiftAvailability` | Extracted from `Shift_GetAvailability` (6.1). |
| `Oee.ufn_ProductionDay(@ShiftId)` | Production day of a shift = Eastern date its scheduled window ends (6.6). |
| `Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId)` | The shift set for a period, built on `ufn_ProductionDay`. Day = the production day's three shifts (3rd -> 1st -> 2nd). Week = Monday-Sunday production week. |
| `Oee.ufn_RejectChargeFamily` | ChargeToParty -> charge family, with the "where found" rule for Non-Specific parties (6.4). |
| `Oee.Dashboard_GetUnitSummary(@Zoom, @AnchorShiftId, @AreaFamily NULL)` | One row per unit (and station rows flagged as such): area family, ProductionArea, pooled minutes, availability, good, scrap, non-reject, no-reason count/minutes, last die, band. Feeds the site cards, area tiles and group headers. |
| `Oee.Dashboard_GetTrend(@AnchorShiftId, @AreaFamily NULL, @LocationId NULL)` | Daily pooled availability and quality for the 7 production days ending at the anchor. |
| `Oee.Dashboard_GetDowntimeByReason(@Zoom, @AnchorShiftId, @AreaFamily NULL, @LocationId NULL)` | Pareto rows: reason, type, planned flag, minutes, count; NULL reason as its own row. |
| `Oee.Dashboard_GetScrap(@Zoom, @AnchorShiftId, @AreaFamily NULL, @LocationId NULL, @GroupBy)` | By defect+part, by part (Trim shop table), or by line (M&A panel). |
| `Oee.Dashboard_GetBreakdown(@Zoom, @AnchorShiftId, @LocationId)` | Drill-down breakdown rows (shifts of a day / days of a week). |
| `Oee.Dashboard_GetDowntimeEntries(@AnchorShiftId, @LocationId)` | Entries for one unit (and its stations) in one shift; or reuse `DowntimeEvent_GetByScope` if it already fits. |
| `Oee.ufn_AreaFamily`, `Oee.ufn_OeeBand` | 6.2, 6.5. |

Tests in `sql/tests/` per existing pattern, including: pooled vs averaged (a 2-hour unit and an 8-hour unit), roll-up line pooling, no-production unit, NULL-reason row, trim scrap on the shop not the press, FIFO scrap appearing on the line, received FG excluded, a DC-charged defect recorded on an M&A line (in Die Cast area quality, not on the line, not on any press), Die Maintenance scrap in Die Cast, Non-Specific scrap where found, a no-cell DC reject at Die Cast area level, and a 3rd shift starting Monday 22:30 grouped into Tuesday.

**Ignition**

- Core: named queries under `oee/` for each proc; script module `BlueRidge.Oee.Dashboard` (thin: calls NQs, returns shaped empty results per the pre-declare rule).
- MPP: three new views under `BlueRidge/Views/ShopFloor/Oee/` (`Site`, `Area`, `Unit`) + shared components (gauge, tile, future card, Pareto bar) under `BlueRidge/Components/Oee/`; pages `/shop-floor/oee`, `/shop-floor/oee/area/:areaKey`, `/shop-floor/oee/unit/:locationId`. Gauge is an SVG (markup in mockup 3).
- Supervisor Dashboard tile wired (5.5); report + registry entry (5.6).

**Docs**: Data Model §6 (new functions/procs, the counting rules), `PROJECT_STATUS.md`, FDS untouched (it is the plan, not the state).

## 9. Later: Performance and OEE

Not built. Recorded so the cards have a destination:

- Ideal cycle time per die or cast part (D2) -- likely on the Tool/Item rather than the unused `RefCycleTimeSec` location attribute, which is per machine.
- Performance = (ideal cycle time x total count) / run time; OEE = A x P x Q.
- Whether to persist `Oee.OeeSnapshot` is decided then, on measured read cost.

## 10. Known limits carried in

- Overrides that cross into the next shift double-count those minutes in both shifts (`Shift_GetAvailability` choice 2).
- DST Sundays are off by an hour's ratio (OI-38).
- Non-Specific rejects with no cell (6.4) are outside dashboard quality.
- Found-downstream scrap is charged to an area, not traced to the press or die that made it. Tracing it through LOT genealogy is possible later and was not chosen now (D11).
- Trim good is per-shift checkpoint credit (6.4), so it can differ from the plant summary, which credits the LOT's current `PieceCount` at Trim OUT.
- **Where the dashboard and `Reject_GetPlantSummary` will still differ:** the plant summary reports Die Maintenance on its own row, while the dashboard folds it into Die Cast (D12). The plant summary counts every FinishedGood LOT, while the dashboard excludes Received-origin FG. Trim good is counted differently (above). Scrap *ownership* agrees; the denominators differ in these three ways.

## 11. Questions put to Jacques -- answered 2026-10-29

1. **Scrap: where found, or charged-to party?** *Charge by defect code, at area level* (D11). Follow-up: Die Maintenance -> Die Cast; Non-Specific MPP / Supplier -> where found (D12). Folded into 5.2-5.4, 6.3, 6.4, 10.
2. **Production day boundary?** *3rd -> 1st -> 2nd*: the Monday 22:30 3rd shift is Tuesday's (D13). Folded into 6.6 and 8. `BusinessDate` is left as is (6.6).
3. **SubAssembly-only M&A lines?** *None at MPP.* FG-only good stands (D14).
4. **Change order?** *No.* Everything ships now, quality included; pages stay "OEE" with Performance and OEE as future cards (D15, Section 3).

## 12. Calls I made (check these)

- Default to last completed shift; "Downtime with no reason" replaces "Open downtime" (5.1).
- `areaKey` routing and the three area families (5.3, 6.2).
- Dimmed "No production" tiles (5.3).
- One "OEE Summary" PDF report (5.6).
- Effective-minutes pooling for roll-up lines (6.3).
- Time-window fallback for reject rows with no shift (6.4).
- Received FG excluded from M&A good (6.4).
- FIFO scrap writer records line and shift (7.1).
- Monday-Sunday weeks, so a week starts at the Sunday 22:30 3rd shift (6.6).
- Production day = date the shift's *scheduled* window ends; `BusinessDate` untouched (6.6).
- Found-downstream scrap shown as its own row on the area scrap panel and greyed on the unit that recorded it (5.3, 5.4).
- No-cell rejects charged to a production area count at that area's level by plant shift (6.4).
- Placeholder colour bands (6.5).
- Trim good from per-shift checkpoint credits, not the whole LOT at Trim OUT; rework passes excluded (6.4).
- Benchmark the availability function before building views (6.1).
