# OEE Dashboard -- Availability and Quality, Site to Unit

**Date:** 2026-10-27
**Status:** v0.3.2 -- v0.3.1 approved 2026-10-30; v0.3.2 is the configuration-fingerprint change Jacques accepted with the v0.3 plan (6.8, D22). Being built.
**Mockups:** `docs/superpowers/specs/2026-10-27-oee-dashboard-mockups/` (open in a browser; the dark-navy frames are the screens, the text around them is commentary)

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-10-27 | First draft from the brainstorm with Jacques. |
| 0.2 | 2026-10-29 | Jacques answered the four open questions (Section 11). Scrap is charged by defect code at area level (6.4); production day runs 3rd -> 1st -> 2nd (6.6); FG-only M&A good confirmed; no change order -- everything ships. |
| 0.3 | 2026-10-30 | Rework after the benchmark gate missed (Section 13). Availability is computed from entered DURATIONS, not clock overlap (6.1, D17). Per-shift figures are stored in a summary table, computed when a shift closes and refreshed within 30 minutes of any later edit, with a nightly safety net (6.7, 6.8, D16, D19). Finished-good LOTs carry the shift they were minted in (7.4, D18). INSP + Offsite lines sit under M&A (D20). Writer inventory added (6.8). |
| 0.3.1 | 2026-10-30 | Q5 and Q6 answered: `Lots.Lot.MintedPieceCount` (D21); changed shifts found by change detection (D22, 6.8). |
| 0.3.2 | 2026-10-30 | Configuration changes are found by a configuration fingerprint instead of edits to ~20 configuration procs (D22, 6.8; accepted with the v0.3 plan). Inventory corrected: `DowntimeEvent_UpdateTimes` does not change `ShiftId`. |

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
- G7. **Every screen answers in under 2 seconds at any zoom**, including a whole-plant Week. Per-shift figures are stored, so a read never recomputes history (6.7).

**Non-goals (this deployment)**

- Performance and OEE numbers. They need ideal cycle times (Section 9).
- Any timeline / Gantt of downtime. Downtime is entered at shift end as durations; clock positions would be fiction.
- PLC-sourced downtime. `DowntimePlcWatcher` is not commissioned (`_WATCH = []`) and there is no Tag Historian.
- Changing how operators record scrap. No new pickers, no per-machine scrap at Trim, no per-side scrap on M&A lines.

**Anti-goals** -- it fails even if it works if:

- It shows a live current-shift number that reads ~100% because nobody has entered downtime yet.
- Area or plant figures average percentages, so a press that ran 2 hours weighs as much as one that ran 8.
- It forces a workflow change operators have refused (live downtime entry, scrap side selection).
- It invents precision: a trim press "quality" figure when trim scrap is only known by shop.
- It under-counts downtime: two 30-minute end-of-shift entries on one press must cost 60 minutes, not 30 (6.1).
- It counts the same pieces twice: splitting, merging or reworking a finished-good LOT is not new production (6.4).

## 3. Constraints

- **Scope.** `reference/MPP_Scope_Matrix.xlsx` rows 16 (OEE) and 18 (KPIs) read "Not Included"; FDS-09-011 tags OEE FUTURE. Row 17 (Downtime) and FDS 9.4 (shift availability, MVP) are in. **Jacques, 2026-10-29: no change order.** Availability, downtime and quality are built and shipped now. The plant already records good and bad parts, and showing two of OEE's three factors has clear precedent. Only Performance and OEE stay as future cards (Section 11, Q4).
- **Downtime is entered at end of shift**, by operators who will not change that. Figures for a shift are only complete once its end-of-shift entry is done.
- **SQL conventions** from CLAUDE.md: read procs return one result set, no OUTPUT parameters, timestamps stored UTC and displayed ET, business rules in SQL not Python, `EXEC` parameters literal or `@variable`.
- **Late entries are normal.** End-of-shift downtime, scrap and die-cast reconciliation routinely arrive after the shift has closed, sometimes much later. Stored figures must follow them (6.8).
- **INSERT-EXEC cannot nest.** Tests capture procs with INSERT-EXEC, so a read proc cannot itself INSERT-EXEC another status-row or read proc; shared logic lives in functions or in the summary table.
- **Ignition**: all named queries in Core; new views in MPP; new view folders need `view.json` + `resource.json`; run `scan.ps1` after adding resources. File edits to existing views are permitted for this work (Jacques, 2026-10-27).
- **Shared Dev DB and gateway.** Do not reset `MPP_MES_Dev`; validate on a throwaway `MPP_MES_Test`.

## 4. The decisions (Jacques's)

| # | Decision |
|---|---|
| D1 | Build now: Availability, downtime, shifts, Quality (good vs scrap). Performance and OEE are darkened future cards. |
| D2 | Performance, when it comes, uses an ideal cycle time **per die or cast part** -- "that's as good as it gets". |
| D3 | On M&A the **line** is the OEE unit. Its stations (Machining, Assembly Conveyor A/B, ...) contribute **downtime only**. Line availability is the mean of its OEE-enabled stations -- which is what `Shift_GetAvailability` v2.0 already does. Kept under D17: a line-level entry counts against every station. |
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
| D16 | **Per-shift figures are stored** in a summary table (6.7) and the dashboard reads them; it does not recompute history on every read (Jacques, 2026-10-30, after the benchmark). |
| D17 | **Availability is computed from entered durations, summed.** Clock-overlap merging is dropped: MPP's downtime is mostly a duration entered at the end of the shift, and those entries all sit at the shift start, so merging them by clock under-counts (6.1). `Oee.Shift_GetAvailability` adopts the same method -- one definition of availability. |
| D18 | **A finished-good LOT records the shift it was minted in** (`Lots.Lot.ShiftId`), stamped by the Assembly OUT mint; existing LOTs are backfilled once (7.4). |
| D19 | **Refresh:** a shift is computed when it closes and recomputed within 30 minutes of any later edit; a nightly sweep rebuilds the last 7 days as a safety net (6.8). The writer inventory has to be complete (6.8). |
| D20 | Inspection (INSP) and Offsite (OS-PROD) OEE lines are units under **M&A**, each in its own ProductionArea group (Jacques, 2026-10-30). |
| D21 | **Minted quantity is stored:** a new column `Lots.Lot.MintedPieceCount`, written by the mint alongside `ShiftId` and never changed afterwards. Good = its sum (6.4, 7.4). Not reconstructed from consumption records (Jacques, 2026-10-30). |
| D22 | **Changed shifts are found by change detection:** every 15 minutes the refresher fingerprints each shift of the last 7 days and recomputes those whose fingerprint differs. Fact writers are not edited. Configuration is fingerprinted the same way (`Oee.ufn_ShiftSummaryConfigFingerprint`): when it changes, every stored shift is recomputed newest first, a bounded number per run; no configuration proc is edited (6.8) (Jacques, 2026-10-30). |

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

### 6.1 Availability -- summed durations (D17)

**Why the method changed.** v0.2 reused `Shift_GetAvailability` v2.0, which merges downtime by clock position on a one-minute grid. That is the right model only when downtime has real start and end times from a live source such as a PLC. MPP's downtime is mostly a duration entered at the end of the shift: `Oee.DowntimeEvent_RecordApproximate` stores it with a nominal window, `StartedAt` = shift start and `EndedAt` = start + duration, and only `DurationMinutes` + `ShiftId` are authoritative (its header says so). Every such entry for a press starts at the same instant, so a clock merge counts a 30-minute and a 45-minute entry as 45 minutes, not 75. Availability would read too high on exactly the data MPP enters most.

**The rule** (standard OEE, per OEE location per shift):

```
PlannedMinutes  = the location's scheduled window for the shift (+ override)   -- unchanged
Downtime        = SUM of the durations of the shift's downtime entries
                  (DowntimeEvent.ShiftId = the shift, not voided)
  duration      = DurationMinutes                 when IsApproximate = 1
                = EndedAt - StartedAt             otherwise; an open entry runs to
                                                  min(now, window end)
PlannedDowntime = entries whose reason IsExcused (Break, lunch, ...)
Unplanned       = every other entry, including entries with no reason
BaseMinutes     = max(0, PlannedMinutes - PlannedDowntime)
Unplanned       capped at BaseMinutes
Availability    = (BaseMinutes - Unplanned) / BaseMinutes      NULL when BaseMinutes = 0
```

- **Which entries a location counts** is unchanged: its own, plus (for a leaf) every flagged ancestor's -- a line-level stop hits each station (D3). A roll-up line is the mean of its stations (D3).
- **Entries are attributed by `ShiftId`**, the shift they were entered against, not by clock overlap with the window. That also retires v2.0's known flaw where an override reaching into the next shift double-counted its minutes.
- **Duplicates are counted twice.** Two people entering the same stop is a data-quality problem the drill-down's entry list shows; the old clock merge hid it.
- `Oee.Shift_GetAvailability` moves to this method (same columns, a new major version) so the plant has one definition. Its tests are rewritten as worked examples (two duration entries at one shift start = their sum; a line entry reaching each station; planned shrinking the base; the cap), not as parity with v2.0.

**Performance.** History is read from the summary table (6.7); only the computation that fills it and the shift in progress use this rule directly. Targets: any dashboard read under 2 s at any zoom; one shift's computation for the whole plant well under a second; a full 7-day rebuild under a minute. The benchmark in `sql/scratch/2026-10-29_oee_dashboard_benchmark.sql` is re-run against these targets before any view work.

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

**Only active (unit, shift) pairs pool**: a unit-shift with good, scrap or a downtime entry (a trim press is active when its shop made or scrapped anything that shift). An idle press would otherwise report 100% and dilute its area (anti-goal). A unit with no active shift in the period shows "No production".

The summary table stores minutes and counts, never percentages, so every zoom pools from the same stored facts.

Units with `BaseMinutes = 0` are excluded from availability (NULL, shown "--").

### 6.4 Good and scrap counts

Good-count rules are the ones already agreed for `Quality.Reject_GetPlantSummary` (Jacques, 2026-08-25), narrowed to a unit and shift:

| Area | Good | Unit it lands on | Shift |
|---|---|---|---|
| Die Cast | `SUM(Workorder.DieCastContribution.PieceDelta)` | `CellLocationId` (the press) | `ShiftId` |
| Trim | **per-shift checkpoint credit**: each trim `ProductionEvent` (partial checkpoint via `TrimPartial_Record`, and the closing `TrimOut`) is credited with its count minus the LOT's previous trim checkpoint -- the rule `TrimPartial_Record` already defines, via `Workorder.ufn_TrimPassPreviousCount` | the Trim Shop above `ProductionEvent.TerminalLocationId` | `ProductionEvent.ShiftId`; rows with `ShiftId NULL` (rework passes) are not shift production and are excluded |
| M&A | the **minted quantity** (`Lot.MintedPieceCount`, D21) of FinishedGood LOTs minted at Assembly OUT | the line above `Lot.CreatedAtTerminalId` | `Lot.ShiftId` (D18) |

**Why the M&A rule changed.** v0.2 counted every Manufactured FinishedGood LOT by `CreatedAt`. The writer inventory (6.8) showed that `Lots.Lot_Split`, `Lots.Lot_Merge` and `Lots.ContainerRework_MovePieces` also create LOTs stamped `Manufactured` with a fresh `CreatedAt` -- splitting or reworking a tray would have counted as new production. And `PieceCount` shrinks when the LOT is later scrapped, so the same pieces would have been charged as both less good and as scrap. Good is therefore the quantity **at mint**, on LOTs that **only the mint** stamps with a shift. Split, merge and rework children never carry `ShiftId`. Received-origin LOTs stay excluded, so a part received finished is not counted twice. (The plant summary counts every FinishedGood LOT; whether that proc double-counts is a side observation for the builder, not a fix here.)

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

### 6.7 The summary table (D16)

**`Oee.ShiftSummary`** -- one row per (shift, location) where location is an OEE unit, a station, or an area-level placement (a trim shop), plus one row per (shift, area family) for scrap charged to an area but placed on no unit. Additive facts only:

| Column group | Columns |
|---|---|
| Key | `ShiftId`, `LocationId` (NULL on an area-charge row), `RowKind` (`Unit` / `Station` / `AreaPlacement` / `AreaCharge`), `AreaFamily`, `ProductionAreaId`, `ParentUnitLocationId` |
| Time | `PlannedMinutes`, `PlannedDowntimeMinutes`, `UnplannedDowntimeMinutes`, `BaseMinutes`, `EffectiveUnplannedMinutes` (roll-up lines), `DowntimeEventCount`, `NoReasonCount`, `NoReasonMinutes` |
| Quality | `Good`, `Scrap`, `NonRejectScrap`, `FoundDownstreamScrap`, `UnplacedScrap` |
| Context | `LastToolId` (presses), `IsActive` |
| Bookkeeping | `ComputedAt`, `InputFingerprint` |

- **No percentages are stored.** Every read pools from the minutes and counts (6.3), so a Week is never an average of averages.
- **Detail panels read the source rows directly** by `ShiftId` (downtime by reason, scrap by defect, the entry list): indexed range reads over a period's rows, measured at about 100 ms for a whole-plant week. Only the expensive pooled metrics live in the table.
- **The shift in progress is never stored.** It is computed live with the same procedure, for one shift.
- **Size.** About 60 units x 3 shifts x 365 days, roughly 65k rows a year. Kept indefinitely, not partitioned.
- One proc, **`Oee.ShiftSummary_Compute(@ShiftId)`**, computes and replaces one shift's rows in a single transaction. The shift-close compute, the refresher, the nightly sweep and the in-progress read all use the same calculation.

### 6.8 Refresh: closed shifts, late edits, safety net (D19)

**When a shift is computed.**
1. **At shift close.** The `ShiftBoundaryTicker` already ends shifts; the shift is computed then.
2. **Within 30 minutes of any later edit.** A gateway timer runs every 15 minutes and recomputes every shift whose inputs changed since it was computed (below).
3. **Nightly safety net.** A full rebuild of the last 7 days catches anything the change detection missed.
4. **On request.** `Oee.ShiftSummary_RecomputeRange(@FromUtc, @ToUtc, @AppUserId)` for data repairs and deployments.

The dashboard labels a shift that closed less than an hour ago "entries may still be arriving" (my call).

**How a changed shift is found: change detection (D22).**

Every 15 minutes the refresher computes a cheap fingerprint per shift for the last 7 days over the fact tables below (row count, quantity sums, a checksum of the columns the calculation reads) and recomputes the shifts whose fingerprint differs from the stored `InputFingerprint`. No fact writer changes, and a writer added next year is covered automatically. An edit that moves a row to another shift (the restamps) changes both shifts' fingerprints, so both are recomputed.

**Configuration changes** do not alter fact rows, so they are fingerprinted separately: `Oee.ufn_ShiftSummaryConfigFingerprint` hashes the configuration tables below (schedules, reason codes' `IsExcused`, defect codes' charge party and non-reject flag, locations' OEE flag / parent / type, type-definition codes). When it differs from the stored one (`Oee.ShiftSummaryConfig`), every stored shift computed before the change is stale and `Oee.ShiftSummary_RefreshChanged` recomputes them newest first, `@MaxShifts` per run (default 60). A configuration change such as flipping `IsExcused` affects all history, which is too much to recompute inside the configuration proc's transaction. No configuration proc is edited, and a configuration writer added later is covered. Shift overrides and tool assignments affect only their own day or press, so they are in the per-shift fingerprint instead.

*Not chosen:* every writer calling a mark-stale proc inside its transaction -- exact, but every current and future writer has to remember.

The inventory below is the contract: each entry gets a test that an edit through it changes the fingerprint and reaches the summary.

**Writer inventory -- fact tables** (repeatable procs that INSERT / UPDATE / DELETE, alias forms included; checked 2026-10-30):

| Input | Writers |
|---|---|
| `Oee.DowntimeEvent` | `DowntimeEvent_Start`, `_End`, `_RecordApproximate`, `_RecordHistorical`, `_UpdateReason`, `_UpdateTimes` (changes duration, never `ShiftId`), `_Void`; `EndOfShiftEntry_Submit`; `DowntimeReasonCode_Assign`; `ShiftOverride_Restamp` (moves `ShiftId`) |
| `Workorder.RejectEvent` | `RejectEvent_Record`, `RejectEvent_RecordByPartFifo`, `DieCastScrap_Write`, `TrimOut_Record`, `TrimPartial_Record`, `MachiningOut_Mint`, `Lots.ContainerRework_Scrap`, `Quality.ControlledRunResult_Record`, `DieCastEntry_Restamp` (moves shift) |
| `Workorder.DieCastContribution` | `DieCastCredit_Write`, `DieCastEntry_Restamp`, `ShiftOverride_Restamp` (`DieCastShiftReconciliation_Save` writes through these) |
| `Workorder.ProductionEvent` (trim checkpoints) | `TrimOut_Record`, `TrimPartial_Record` (also written by `ProductionEvent_Record`, `MachiningIn_RecordPick`, `MachiningOut_Mint`, which the trim credit filters out by operation type) |
| `Lots.Lot` (finished-good mints) | `Assembly_CompleteTray` -- the only writer that stamps `ShiftId` (7.4). The other ~34 `Lots.Lot` writers (moves, holds, splits, merges, status, scrap decrements, rework) cannot change good, because good is the stamped minted quantity. |

**Writer inventory -- configuration** (change how existing rows are read; caught by the configuration fingerprint, except overrides and tool assignments, which are in the per-shift fingerprint):

| Input | Writers | What it changes |
|---|---|---|
| `Oee.Shift` | `Shift_Start`, `Shift_End`, `Shift_Reconcile` | which shifts exist / are closed (`Shift_End` triggers the first compute) |
| `Oee.ShiftOverride` | `ShiftOverride_Create`, `_Update`, `_Deprecate` | planned minutes for one location on one day |
| `Oee.ShiftSchedule` | `ShiftSchedule_Create`, `_Update`, `_Deprecate` | planned minutes plant-wide |
| `Oee.DowntimeReasonCode` | `DowntimeReasonCode_Create`, `_Update` (`IsExcused`), `_Deprecate`, `_BulkLoadFromSeed` | planned vs unplanned |
| `Quality.DefectCode` | `DefectCode_Create`, `_Update` (`ChargeToPartyId`, `IsNonRejectScrap`), `_Deprecate` | which area owns scrap |
| `Location.Location` | `Location_Create`, `_Update`, `_SaveAll`, `_Deprecate`, `_MoveUp`, `_MoveDown` | `IsOeeEnabled`, parentage: which locations are units |
| `Location.LocationTypeDefinition` | `LocationTypeDefinition_SaveAll`, `_Deprecate` | area family of a unit type |
| `Tools.ToolAssignment` | `ToolAssignment_Assign`, `_Release` | the die shown on a press tile |

Versioned migrations that repair data (e.g. `0077`) are one-offs; their deployment runbook calls `RecomputeRange`. The inventory is a test: `sql/tests/0117_Oee_Dashboard/075_writer_inventory.sql` changes every column these writers can change that the calculation reads, and asserts the fingerprint moves. Gateway Python writes no raw SQL to any of these tables (checked: no `runUpdateQuery` / `runPrepUpdate` in project scripts); named queries call the procs above.

## 7. Writer fixes (G6)

1. **`Workorder.RejectEvent_RecordByPartFifo`** (the Scrap Entry popup on Assembly and Machining terminals) inserts `NULL` for `ShiftId` and `CellLocationId`. It already knows the line: `@LocationId` is where it finds the LOTs. Write `CellLocationId = @LocationId` and `ShiftId = (SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@LocationId, <now>))` -- it is an inline TVF keyed on location because overrides make the answer per-equipment; call it the way `TrimOut_Record` does (~377). No signature change; no popup change. *Without this, almost all M&A scrap is invisible to the dashboard* (my call -- it follows D6, and the scrap stays line-level).
2. **`Workorder.MachiningOut_Mint`** writes `CellLocationId` = the LOT's line but no `ShiftId`. Add `ShiftId` from `Oee.ufn_ShiftIdForInstant(<the line>, <now>)`, same call shape (D10).
3. No backfill. The time-window fallback in 6.4 covers older rows that have a cell.

Both are repeatable-proc changes with version bumps and change-log lines; each gets a test asserting the new columns. `Oee.ShiftOverride_Restamp` deliberately ignores reject rows and stays that way. (Built: commit `b1326ab3`.)

4. **`Workorder.Assembly_CompleteTray` stamps the mint (D18).** New nullable columns on `Lots.Lot`: `ShiftId` (FK `Oee.Shift`) and `MintedPieceCount` (D21), both written once by the mint. The mint writes `ShiftId` from `Oee.ufn_ShiftIdForInstant(<the line>, now)`, the same call shape as the scrap writers. `MachiningOut_Mint` stamps its SubAssembly LOTs the same way, for consistency (my call). `Lot_Split`, `Lot_Merge` and `ContainerRework_MovePieces` list their insert columns explicitly and do not copy `ShiftId`; a test pins that.
5. **One-time backfill** (Jacques agreed). A versioned migration (next free number at build time; `0116` is the highest today) stamps existing finished-good LOTs that were **minted** -- the produced side of a `Consumption` genealogy link, or a pass-through mint -- with `ShiftId` resolved from the line and `CreatedAt`, and with a reconstructed minted quantity (current `PieceCount` + pieces scrapped from it + pieces split out of it). Split, merge and rework children are left NULL. The migration reports what it could not reconstruct rather than guessing.

## 8. Build shape

**SQL**

| Object | Purpose |
|---|---|
| Migration (next free number) | `Oee.ShiftSummary` (with `InputFingerprint`); `Lots.Lot.ShiftId` + `MintedPieceCount`; the finished-good backfill (7.4, 7.5). |
| `Oee.Shift_GetAvailability` (new major version) + the availability function behind it | Summed-duration rule (6.1). |
| `Oee.ShiftSummary_Compute(@ShiftId)` | One shift's rows, one transaction (6.7). |
| `Oee.ShiftSummary_RecomputeRange(@FromUtc, @ToUtc)`, `Oee.ShiftSummary_RefreshChanged()` | Configuration changes / deployments; the 15-minute change detection (6.8). |
| `Oee.ufn_ProductionDay`, `Oee.ufn_ShiftsForPeriod` | Production day and period (6.6). Built. |
| `Oee.ufn_OeeUnits`, `Oee.ufn_AreaFamily`, `Oee.ufn_RejectChargeFamily`, `Oee.ufn_OeeBand` | Classification (6.2, 6.4, 6.5). Built. |
| `Oee.Dashboard_GetUnitSummary`, `_GetTrend`, `_GetBreakdown` | Pool from `Oee.ShiftSummary` (+ the live in-progress shift). |
| `Oee.Dashboard_GetDowntimeByReason`, `_GetScrap`, `_GetDowntimeEntries`, `_GetPeriod` | Detail panels and navigation, read from source rows by `ShiftId`. |

**Gateway (Core):** a 15-minute timer calling `RefreshChanged`, a nightly 7-day rebuild, and the shift-close compute hooked to the `ShiftBoundaryTicker`; all attributed to the system user (`Common.Util.systemAppUserId()`), committed disabled per the timer convention.

Tests in `sql/tests/` per existing pattern, including: two duration entries at one shift start summed; a line entry reaching each station; the unplanned cap; a split / merge / rework child not counted as good; a later scrap not shrinking good; every inventory writer reaching the summary (6.8); pooled vs averaged (a 2-hour unit and an 8-hour unit), roll-up line pooling, no-production unit, NULL-reason row, trim scrap on the shop not the press, FIFO scrap appearing on the line, received FG excluded, a DC-charged defect recorded on an M&A line (in Die Cast area quality, not on the line, not on any press), Die Maintenance scrap in Die Cast, Non-Specific scrap where found, a no-cell DC reject at Die Cast area level, and a 3rd shift starting Monday 22:30 grouped into Tuesday.

**Ignition**

- Core: named queries under `oee/` for each proc; script module `BlueRidge.Oee.Dashboard` (thin: calls NQs, returns shaped empty results per the pre-declare rule).
- MPP: three new views under `BlueRidge/Views/ShopFloor/Oee/` (`Site`, `Area`, `Unit`) + shared components (gauge, tile, future card, Pareto bar) under `BlueRidge/Components/Oee/`; pages `/shop-floor/oee`, `/shop-floor/oee/area/:areaKey`, `/shop-floor/oee/unit/:locationId`. Gauge is an SVG (markup in mockup 3).
- Supervisor Dashboard tile wired (5.5); report + registry entry (5.6).

**Docs**: Data Model §6 (new functions/procs, the counting rules), `PROJECT_STATUS.md`, FDS untouched (it is the plan, not the state).

## 9. Later: Performance and OEE

Not built. Recorded so the cards have a destination:

- Ideal cycle time per die or cast part (D2) -- likely on the Tool/Item rather than the unused `RefCycleTimeSec` location attribute, which is per machine.
- Performance = (ideal cycle time x total count) / run time; OEE = A x P x Q.
- Performance adds ideal-cycle facts to `Oee.ShiftSummary`; nothing else about storage changes.

## 10. Known limits carried in

- Duplicate downtime entries for the same stop are counted twice (6.1); the entry list on the drill-down is where they show.
- An entry with real start and end times that runs past its shift's end is counted in full against the shift it was entered against.
- Edits older than the 7-day safety window reach the summary only through change detection (if within its window) or an explicit `RecomputeRange`.
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

**Answered 2026-10-30:** INSP + Offsite lines under M&A (D20); stored per-shift figures with stale refresh and a nightly safety net (D16, D19); fix availability (D17); `ShiftId` on the finished-good LOT with a one-time backfill (D18).

**Answered 2026-10-30 (v0.3):**

5. **The minted quantity.** *Stored:* `Lots.Lot.MintedPieceCount`, written by the mint (D21).
6. **How a changed shift is found.** *Change detection* by fingerprint (D22, 6.8).

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
- Benchmark before building views (6.1) -- kept, against the v0.3 targets.
- Only active (unit, shift) pairs pool (6.3).
- "Entries may still be arriving" label for a shift closed under an hour ago (6.8).
- `MachiningOut_Mint` stamps `ShiftId` on SubAssembly LOTs too (7.4).
- Detail panels read source rows; only pooled metrics are stored (6.7).

## 13. Build record -- why v0.3

v0.2 was approved on 2026-10-29 and built as plan Tasks 1-6 on `jacques/working` (`b1326ab3`..`970de47d`, SQL only, tests green). The Task 7 benchmark -- a month of synthetic data on `MPP_MES_Test`: 58 units, 90 shifts, 31k downtime entries, 12.6k finished-good LOTs, 10k rejects -- missed the 2 s target badly:

| Zoom | Measured (whole plant) |
|---|---|
| Shift | 1.1-1.2 s |
| Day | 2.2-3.8 s |
| Week | 12.6-24.8 s |

Stepped timing of one Week read: re-resolving each finished-good LOT's shift 9.3 s, the minute-grid availability 2.8 s, everything else under 0.5 s. The data volume was never the problem; recomputing every shift on every read, and re-deriving facts that should have been recorded, was. Reviewing that with Jacques also surfaced the duration-stacking flaw (6.1) and the split/merge double-count (6.4).

**Carried forward from the build:** the scrap writer fixes (Task 1); the classification functions; production day and periods; the scrap placement function; the test fixture (`sql/tests/helpers/0117_fixture_oee_dashboard.sql`) and the classification, production-day and scrap tests.

**Replaced:** the minute-grid availability function and `Shift_GetAvailability` v3.0 (by the summed-duration rule); the finished-good branch of the good count (by the mint stamp); `Dashboard_GetUnitSummary`'s per-shift recomputation (by reads from `Oee.ShiftSummary`).
