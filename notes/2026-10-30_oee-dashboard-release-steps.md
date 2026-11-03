# OEE dashboard -- what the prod release must contain (2026-10-30)

Input for the release runbook of the OEE dashboard (spec
`docs/superpowers/specs/2026-10-27-oee-dashboard-design.md` v0.3.2, plan
`docs/superpowers/plans/2026-10-30-oee-dashboard-v03.md`). This is not the runbook:
the release still ships as the five-part contract in `prod-release-context-pack/`
(preview, rehearsal, fingerprint-guarded execute, scoped exports, published guide).
It lists the steps specific to this feature, in order, and why each is there.

## SQL, in this order

1. **Migration `0117_oee_shift_summary`** -- `Lots.Lot.ShiftId` + `MintedPieceCount`,
   `Oee.ShiftSummary`, `Oee.ShiftSummaryConfig`. Additive; no existing row changes.
2. **Repeatables** (the normal repeatable deploy). Two procs change behaviour on the
   floor, both additive:
   - `Workorder.Assembly_CompleteTray` v1.6 and `Workorder.MachiningOut_Mint` v2.9
     now stamp `ShiftId` + `MintedPieceCount` on the LOT they mint.
   - `Oee.Shift_GetAvailability` v4.0: availability is now the SUM of entered
     durations by `ShiftId` (D17). **Numbers on any screen that already shows
     availability will drop where two end-of-shift entries overlapped** -- that is
     the fix, not a regression. Say so in the guide.
3. **Backfill the mint stamp** on LOTs minted before 0117:
   - `EXEC Lots.Lot_BackfillMintStamp @Commit = 0, @AppUserId = <SYS>;`
     run standalone it performs the UPDATE and rolls back. Read the report:
     `Stamped` / `NoShift` / `NotReconstructable` per LOT. NoShift and
     NotReconstructable are left NULL and stay out of good -- expected for a few
     LOTs; a large count is a stop-and-ask.
   - Then `@Commit = 1`. A second run must report 0 `Stamped`.
4. **Fill the summary for all history**:
   `EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = <earliest shift>, @ToUtc = <now + 1 day>, @AppUserId = <SYS>;`
   Benchmark: a month of whole-plant shifts in ~9 s, so a year is minutes. It
   commits shift by shift; a failure keeps what it finished and can be re-run.
5. **Record the configuration fingerprint**: one call to
   `EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = <SYS>;` (its first run only
   records the fingerprint; it must not see "everything changed").

## Ignition, in this order

1. **Core** (import first): named queries `oee/ShiftSummary_RefreshChanged`,
   `oee/ShiftSummary_RecomputeRange`, `oee/Dashboard_*` (7); script modules
   `BlueRidge.Oee.Summary`, `BlueRidge.Oee.Dashboard`; the modified
   `BlueRidge.Oee.Shift` (`tickShiftBoundary` now refreshes the summary when it
   closes a shift).
2. **MPP**: the OEE views and page routes, the Supervisor Dashboard tile, the
   report, and the two timers `OeeSummaryRefresh` (15 min) and `OeeSummaryNightly`
   (daily). **The timers are committed disabled. Enable both after steps SQL 1-5.**

## Verification after the window

- `SELECT COUNT(DISTINCT ShiftId) FROM Oee.ShiftSummary` equals the number of closed
  shifts.
- Within one shift change, the closed shift appears in `Oee.ShiftSummary`
  (the ticker hook), and `Oee.ShiftSummaryConfig.CheckedAt` advances every 15 min
  once the refresh timer is on.
- `/shop-floor/oee` opens on the last completed shift; a Week read is well under
  2 s.

## Rollback

- Disable both timers; the dashboard pages can be hidden by removing their routes.
- The SQL is additive: leaving `0117`'s columns and tables in place is harmless.
  Reverting the repeatables restores clock-merged availability and unstamped mints;
  stamped LOTs keep their stamp (nothing else reads it).
