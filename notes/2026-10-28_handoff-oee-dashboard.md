# Handoff -- OEE dashboard (availability + quality), 2026-10-28

> **CLOSED 2026-11-03.** The dashboard is built (plan Tasks 1-16, spec v1.0). Nothing here is
> pending. What ships and in what order: `notes/2026-10-30_oee-dashboard-release-steps.md`.
> Where the build differs from the spec: spec Section 14. Schema: `MPP_MES_DATA_MODEL.md`
> v3.11. The sections below are history.

**Read this first, then the spec.** Everything needed to continue is in the repo. The
conversation it came from (2026-10-27) is not needed.

| Artifact | Path |
|---|---|
| Design spec (v1.0, built) | `docs/superpowers/specs/2026-10-27-oee-dashboard-design.md` |
| Approved mockups (open in a browser) | `docs/superpowers/specs/2026-10-27-oee-dashboard-mockups/` -- `1-site-overview.html`, `2-area-pages.html`, `3-unit-drilldown.html` |
| This note | `notes/2026-10-28_handoff-oee-dashboard.md` |

The mockup files are fragments written for the superpowers brainstorming "visual companion"
frame; they render fine opened directly in a browser (unstyled page chrome, styled screens).

## Update 2026-10-29 -- approved, plan written

Jacques answered the four questions and **approved spec v0.2**. The answers are in spec Section 11 and decisions D11-D15. The implementation plan is `docs/superpowers/plans/2026-10-29-oee-dashboard.md`. Next: choose an execution method and start Task 1. The questions and steps below are historical.

Note: the highest versioned migration is now `0116` (AIM FailureLog). The plan needs none; re-check before adding one.

## Update 2026-11-03 -- v0.3 plan Tasks 1-12 built (SQL + gateway); views next

Plan: `docs/superpowers/plans/2026-10-30-oee-dashboard-v03.md` (spec v0.3.2). Ledger with every
ruling: `.superpowers/sdd/2026-10-30-oee-dashboard-v03/progress.md` (git-ignored). Commits
`bbb6284` .. `4d97abb` on `jacques/working`.

- Built: migration `0117` (ShiftSummary, ShiftSummaryConfig, Lot.ShiftId/MintedPieceCount);
  mint stamps; `Lots.Lot_BackfillMintStamp`; availability v4.0 (summed durations);
  ShiftSummary compute / fingerprints / refresh; every dashboard read proc; Core NQs,
  `BlueRidge.Oee.Summary` / `.Dashboard`, two MPP timers (committed DISABLED), shift-close hook.
- **Benchmark gate met**: whole-plant Week 40 ms warm (was 24.8 s), one shift's compute
  ~100 ms, a month's fill ~9 s. Full SQL suite 5601/5601.
- `MPP_MES_Dev` now has `0117` and the OEE repeatables (applied 2026-11-03), and some
  `Oee.ShiftSummary` rows. Scan done.
- Release specifics: `notes/2026-10-30_oee-dashboard-release-steps.md`.
- **Next: plan Tasks 13-15** (Site / Area / Unit views, components, Supervisor tile, report),
  then Task 16 (Data Model doc, PROJECT_STATUS, spec v1.0), then the final whole-branch review
  (executing-plans). The read API the views call is `BlueRidge.Oee.Dashboard`
  (period, unitSummary, trend, breakdown, downtimeByReason, scrap, downtimeEntries).

## Update 2026-10-30 (later) -- spec v0.3 written, awaiting re-approval

After the gate miss, Jacques reviewed the design: the whole-plant Week read was 12.6-24.8 s
because every shift was recomputed on every read and facts were re-derived instead of
recorded. Agreed direction, now spec v0.3 (sections 6.1, 6.7, 6.8, 7.4-7.5, 13):
- Availability from **summed durations** (the clock-overlap merge under-counts end-of-shift
  duration entries, which all sit at shift start). `Shift_GetAvailability` adopts it.
- Per-shift figures stored in **`Oee.ShiftSummary`**: computed at shift close, refreshed within
  30 min of any later edit (15-min timer), nightly 7-day safety rebuild.
- **`Lots.Lot.ShiftId`** stamped by the Assembly OUT mint, one-time backfill. Good = quantity at
  mint (split / merge / rework children create new Manufactured LOTs and must not count).
- Full writer inventory in spec 6.8.
Q5/Q6 answered same day (spec v0.3.1): `Lots.Lot.MintedPieceCount` (D21); change detection
by fingerprint, no writer edits (D22). Waiting on re-approval of the spec as a whole.
The plan must be rewritten after re-approval; Tasks 1-6 code is partly carried forward
(spec 13).

## Update 2026-10-30 -- building; STOPPED at the benchmark gate (plan Task 7)

Running the plan natively on `jacques/working`. Ledger (rulings, per-task evidence):
`.superpowers/sdd/2026-10-29-oee-dashboard/progress.md` (git-ignored).

Done and committed (all SQL, tests green; nothing in Ignition yet):
- Task 1 `b1326ab3` -- FIFO + mint scrap stamp line and shift.
- Task 2 `202010d4` -- `Oee.ufn_ShiftAvailability` (TVF), `Shift_GetAvailability` v3.0 over it.
- Task 3 `8958adc2` -- `ufn_OeeUnits`, `ufn_AreaFamily`, `ufn_RejectChargeFamily`, `ufn_OeeBand`; test fixture `helpers/0117_fixture_oee_dashboard.sql`.
- Task 4 `e4f87746` -- `ufn_ProductionDay`, `ufn_ShiftsForPeriod`.
- Task 5 `7e6c0382` -- `ufn_ShiftGood`, `ufn_ShiftScrap`.
- Task 6 `970de47d` -- `Oee.Dashboard_GetUnitSummary`.
- Task 7 tuning `03d43782` -- faster minute grid + ancestor-walk `ufn_AreaFamily`; benchmark script `sql/scratch/2026-10-29_oee_dashboard_benchmark.sql`.

Jacques ruled during the build: INSP and OFFSITE OEE lines go under M&A ("Both under M&A").

**The gate missed.** On `MPP_MES_Test` with a month of synthetic data (58 units, 90 shifts,
31k downtime events, 12.6k FG LOTs, 10k rejects), a whole-plant summary takes Week 24.8 s,
Day 3.8 s, Shift 1.2 s (target: Week < 2 s). Per shift: availability ~0.7 s, good ~0.6 s,
scrap ~60 ms. Indexes made no difference. Recomputing every shift on every read cannot reach
2 s for a week. Spec 6.1 makes the per-shift cache Jacques's call -- **waiting on that decision**.
Next after it: `Dashboard_GetPeriod` (rest of Task 7), then Tasks 8-14.

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
