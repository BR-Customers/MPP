# Handoff -- OEE dashboard (availability + quality), 2026-10-28

**Read this first, then the spec.** Everything needed to continue is in the repo. The
conversation it came from (2026-10-27) is not needed.

| Artifact | Path |
|---|---|
| Design spec (draft 0.1, NOT approved) | `docs/superpowers/specs/2026-10-27-oee-dashboard-design.md` |
| Approved mockups (open in a browser) | `docs/superpowers/specs/2026-10-27-oee-dashboard-mockups/` -- `1-site-overview.html`, `2-area-pages.html`, `3-unit-drilldown.html` |
| This note | `notes/2026-10-28_handoff-oee-dashboard.md` |

The mockup files are fragments written for the superpowers brainstorming "visual companion"
frame; they render fine opened directly in a browser (unstyled page chrome, styled screens).

## Update 2026-10-29 -- approved, plan written

Jacques answered the four questions and **approved spec v0.2**. The answers are in spec Section 11 and decisions D11-D15. The implementation plan is `docs/superpowers/plans/2026-10-29-oee-dashboard.md`. Next: choose an execution method and start Task 1. The questions and steps below are historical.

Note: the highest versioned migration is now `0116` (AIM FailureLog). The plan needs none; re-check before adding one.

## Where it stood (2026-10-28)

1. Research done: how operators and gateway processes feed the OEE tables (spec sections 1, 6, 7).
2. Screens designed and approved by Jacques: site screen (one card per area), the three area
   pages, the unit drill-down "v5".
3. Spec written and put through a builder check (a fresh reviewer read it as the builder and
   checked it against the SQL). Its corrections are folded in.
4. **Blocked on four questions for Jacques** (below). Nothing is built, nothing is committed
   unless this note says so in git history.

## Next steps, in order

1. Get Jacques's answers to the four questions. Fold them into the spec: section 11 (open
   questions) becomes the answers, and update sections 4 / 6.4 / 8 as they dictate.
2. Hand Jacques the spec with the "Calls I made" list (section 12) to check. **Nothing gets
   built until he approves the written spec** (superpowers brainstorming hard gate).
3. After approval: `superpowers:writing-plans` -> plan at
   `docs/superpowers/plans/2026-10-2x-oee-dashboard.md`, then build.
4. First build task is the **benchmark** in spec 6.1 (availability TVF at Week zoom, < 2 s),
   before any view work.

## The four open questions (most important first)

1. **Scrap attribution: where found, or charged-to party?** `Quality.Reject_GetPlantSummary`
   charges rejects by defect code (`DefectCode.ChargeToPartyId`) -- a DC-coded defect found on
   an M&A line lands on Die Cast (header, lines ~10-27, ~90-97). The spec (6.4) charges by
   `RejectEvent.CellLocationId` (where recorded). The two screens would disagree. Lean offered
   to Jacques: charge by defect code to match the report everyone uses -- his call.
2. **Production day boundary.** Code: the 3rd shift starting 22:30 is the LAST shift of the date
   it starts on (`Shift_GetAvailability` takes `BusinessDate = CAST(ActualStart AS DATE)`;
   `ufn_ShiftIdForInstant` sends 02:00 to the previous date's 3rd shift, rule (2)). The spec
   assumed 3rd -> 1st -> 2nd. Which does the plant use? Decides Day/Week grouping
   (`ufn_ShiftsForPeriod`, trend, breakdown) and week edges.
3. **SubAssembly-only M&A lines?** M&A good = Manufactured FinishedGood LOTs. A line whose
   output is a SubAssembly finished elsewhere would show scrap against zero good (0 %). If such
   lines exist, SubAssembly mints need to count as that line's good.
4. **Change order?** Scope matrix rows 16 (OEE) and 18 (KPIs) say "Not Included"; FDS-09-011
   tags OEE FUTURE. Decides whether the Supervisor Dashboard tile and the PDF report ship now.

## Decisions Jacques made (also spec section 4)

- Build now: availability, downtime, shifts, quality. Performance + OEE = darkened
  "Coming in a future deployment" cards.
- Future Performance: ideal cycle time per die or cast part.
- M&A: the LINE is the OEE unit; stations contribute downtime only; line availability = mean of
  its OEE-enabled stations (existing `Shift_GetAvailability` v2.0 behaviour).
- `Location.IsOeeEnabled` decides units (already true in code).
- Trim scrap stays at shop level (part known via `RejectEvent.ItemId`). M&A scrap stays line
  level. **No scrap side picker** -- "no need to force something operators and staff are not
  ready to integrate."
- Downtime is entered only at end of shift and operators refuse to change -> **no timelines**.
  No PLC data. Zoom Shift -> Day -> Week.
- Overview opens on the last completed shift; "Downtime with no reason" replaces "Open downtime".
- Area tiles show the die (not the part); M&A scrap panel lists scrap by line.
- Fix `MachiningOut_Mint` to stamp ShiftId; no backfill.
- Jacques permitted file edits to existing views for this work ("you can make all edits").

## Facts verified in code (so you don't re-derive them)

- `Oee.Shift_GetAvailability` v2.0.1 is the only availability calc; only caller is NQ
  `oee/Shift_GetAvailability` via `BlueRidge.Oee.ShiftOverride.availability(OrEmpty)`; no view
  calls it. It uses `#temp` tables + `WHILE` -> a TVF version is a rewrite.
- `Oee.ufn_ShiftIdForInstant(@LocationId, @Instant)` is an inline TVF; call as
  `SELECT TOP 1 ShiftId FROM ...` like `TrimOut_Record` (~377).
- `Workorder.RejectEvent_RecordByPartFifo` v1.1 inserts NULL ShiftId + NULL CellLocationId
  (~366-377) although `@LocationId` is the line -> most M&A scrap invisible today. Spec 7.1
  fixes it with no signature change.
- `MachiningOut_Mint` v2.7 stamps CellLocationId = line, ShiftId NULL (~270-274).
- Trim reject `CellLocationId` = the trim AREA (shop), by design (guards 3b/5 in TrimOut_Record).
- `TrimPartial_Record` credits per shift = ShotCount minus previous trim checkpoint
  (`Workorder.ufn_TrimPassPreviousCount`); rework passes carry ShiftId NULL. Spec now uses this.
- `Workorder.ProductionEvent` has no location column except `TerminalLocationId`; `ShiftId`
  added by `0096`.
- `Oee.OeeSnapshot` is not created by any migration. `RefCycleTimeSec` / `OeeTarget` location
  attributes exist but are never seeded or read. `DowntimePlcWatcher._WATCH = []`.
- Existing pieces to reuse: `Popups/DowntimeEditor` (Edit link), Supervisor Dashboard stub tile
  "Shift Availability", reports registry `BlueRidge.Reports.registry()` in Core.
- Area names (location seed): Die Cast 1-4, Trim Shop 1-2 (presses `TRIM1-P01..P03`,
  `TRIM2-P01..P03`), Machining & Assembly 1-2 (ProductionLines).
- Highest migration on `jacques/working` at handoff: `0115_terminal_default_machines`. The spec
  expects repeatables only; if a versioned migration is needed, re-check the next free number.

## Process notes

- Work on `jacques/working`; stage explicit paths; no `Co-Authored-By` trailer.
- Shared gateway + `MPP_MES_Dev`: don't reset; validate SQL on a throwaway `MPP_MES_Test`.
- To re-show mockups with the brainstorming companion:
  `bash <superpowers>/skills/brainstorming/scripts/start-server.sh --project-dir <repo> --background`,
  then copy a mockup into the new session's `content/` folder. `.superpowers/` is gitignored --
  the copies under `docs/` are the durable ones.
