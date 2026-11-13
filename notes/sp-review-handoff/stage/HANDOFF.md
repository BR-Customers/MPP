# Stored-procedure review: hand-off

Written 2026-11-13 (about 16:30 local) so someone else can continue the work. Everything the work depends on is in this folder or in the PRs.

## 1. What this is

A review of all 555 stored procedures (`sql/migrations/repeatable/R__*.sql` that create a procedure) for **performance and collision / concurrency** problems, prompted by the 2026-11-10 prod incident (`notes/2026-11-10_prod-incident-assembly-out-deadlock.md`, fixed by migration `0118`). The rules are Jacques's, in `CLAUDE.md` section "Stored-procedure review": one proc revision = one branch = one PR into `main`; never commit to `main` or `jacques/working`; never run anything against prod; never merge your own PR; ask before rewriting behaviour.

## 2. Where things stand

All 555 procs were read once by read-only reviewer agents (batches in `review/chunks`, reports in `review/results`). Counts (same in `SP_REVIEW_CHECKLIST.md` and the review log): **484 checked, no changes / 8 checked and edited / 63 not yet checked (all 63 flagged)**.

| PR | What | Needs `0118`? |
|---|---|---|
| 7 | `Lot_GetComponentsAtCell` v1.2 | Yes. Without it still far faster than v1.1 but back to a single-threaded heap scan |
| 8 | `Lot_GetInspectionQueueByLocation` v1.1 | Same as 7. Worse than v1.0 in reads for a very large queue (600 open LOTs) |
| 9 | `Assembly_GetTraysRemaining` v1.1 | **Yes. Without it SLOWER than v1.0** |
| 10 | ShippingLabel banner index, migration `0120` | No |
| 11 | `Lot_GetLineInventoryByPart` v1.4 | **Yes. Without it MUCH slower than v1.3** |
| 12 | The review log and this folder | - |
| 13 | ContainerRework index, migration `0121` | No |
| 14 | `Item_ListEligibleFinishedGoodsRanked` v1.2 | Benefits; neutral without it |
| 15 | Die-cast recent-creations index, migration `0122` | No |

Each PR body has: problem and evidence, what changed, result-set proof (order-sensitive checksum), cold/warm runtimes, trade-offs, blast radius, version bump, tests, and what was not done. Read the PR bodies for the numbers.

Migration numbers: `0119` is claimed by the container-as-LOT branch (see `PROJECT_STATUS.md`), `0120`/`0121`/`0122` are used by PRs 10/13/15. **The next free number is `0123`.** Renumber if the PRs merge in a different order.

`0118` itself: `PROJECT_STATUS.md` (2026-11-10) says it is packaged but NOT deployed to prod. Nobody has checked prod. Ship `0118` first or with PRs 7, 8, 9, 11.

## 3. What is in this folder

- `SP_REVIEW_CHECKLIST.md` - all 555 procs with their status (same labels and counts as the review log).
- `data/status.csv` - the source of truth for the status of every proc (Proc, Status = complete / edited / pending, Note). `data/all_procs.txt` - the 555 proc file names.
- `tools/` - PowerShell that rebuilds the checklist and the log from `status.csv` (they share one label source so the two files cannot drift), and merges a reviewer-agent report into `status.csv`.
- `perf/` - the SQL used to load realistic test data into the throwaway performance database and to measure each proc before and after (reads, order-sensitive checksum, cold and warm timing).
- `review/review_brief.md` - the instructions given to each reviewer agent. `review/chunks/` - the 12 batches of proc names. `review/results/` - the 12 detailed agent reports (quoted lines, what was verified vs inferred, callers).

## 4. Set-up on a new machine

1. A local SQL Server (Windows auth). `sql/scripts/Reset-DevDatabase.ps1` builds a database from the migrations; `sql/tests/Run-Tests.ps1` resets and fills `MPP_MES_Test` (a throwaway; it DROPS its target) and runs the whole suite. Baseline on `main` when this was written: **5,623 passed / 0 failed**.
2. A second throwaway for measuring: `.\sql\scripts\Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Perf -SkipDemoSeed`, then load data with `perf/load_perf.sql`, `perf/load_perf_insp.sql`, `perf/gtr_setup.sql`, `perf/banner_perf.sql`, `perf/rw_setup.sql`, `perf/trc_setup.sql` (run with `sqlcmd -I`, see gotchas). These make about 80k LOTs, inspection samples, labels, containers and die-cast LOTs, so scans cost something. **Never use Dev or prod for this.**
3. `gh` (GitHub CLI), signed in with write access to `BR-Customers/MPP`.
4. Set `SQLCMDLOGINTIMEOUT=90` in the shell before running the test runner (see gotchas).

## 5. How one fix is done (about 30 minutes, 10-15 of them the test suite)

1. `git fetch origin` then `git switch -c sp/<schema>-<Proc> origin/main`. One proc per branch.
2. Read the proc, find its callers (`grep` `ignition/` for the named query and script wrapper, then the view binding and its poll interval). Do not trust a reviewer-agent claim until you have read the code.
3. Measure the original on `MPP_MES_Perf`: `SET STATISTICS IO`, an order-sensitive `CHECKSUM_AGG`, cold (after `ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE`) and 20-30 warm runs. `perf/*measure*.sql` are templates.
4. Make the change in the `R__*.sql` file (bump the header version and add a change note), or a new numbered migration for an index. Keep the result set identical. ASCII only.
5. Re-measure; the checksum must match. **Also measure with the `0118` indexes dropped** if the change relies on them (then restore with `sql/migrations/versioned/0118_lot_open_lot_indexes.sql`), and say what happens.
6. Add or extend a test under `sql/tests/`; run it against the new proc AND the original (`git show origin/main:<path>`); it must pass on both when it pins existing behaviour.
7. Run the full suite for the before/after count. Do not open the PR if anything fails.
8. Commit (no `Co-Authored-By` trailer, per `CLAUDE.md`), push by explicit refspec: `git push origin <branch>:refs/heads/<branch>`.
9. Open the PR with the same sections as PRs 7-15, written as a UTF-8 file with **no BOM** (use a file, not PowerShell's `Set-Content`).
10. Update `data/status.csv`, then `tools/Build-Checklist.ps1` and `tools/Build-ReviewLog.ps1` (push the log to `sp/review-log`).

## 6. Gotchas that cost time

- `sqlcmd` logins time out intermittently; the test runner then fails to reset the database. Set `SQLCMDLOGINTIMEOUT=90`, retry.
- Filtered indexes need `QUOTED_IDENTIFIER ON`, so run SQL files with `sqlcmd -I`.
- Do not switch branches while the full suite runs; it reads the working tree.
- A temporary `git worktree` fails on Windows (some repo paths are too long). To update another branch without checking it out, build the commit with `git hash-object`, `update-index --cacheinfo`, `write-tree`, `commit-tree`, then push the commit.
- PowerShell 5.1's `Set-Content -Encoding utf8` adds a BOM and mangles emoji read with `Get-Content`; it broke a PR body once. Read and write with .NET (`[IO.File]::ReadAllText/WriteAllText`, `UTF8Encoding($false)`).
- GitHub treats `@Name` in a PR body as a user mention; put SQL parameters in backticks.
- Table variables take their row estimate at first compile; a wide first call can cache a worse plan for later narrow calls (PR 8 measured this at 600 open LOTs).
- `LotMovement` is partitioned monthly; a per-LOT seek probes every partition (17 in the test DB), so reads rise even when scans fall.

## 7. What is next (one task at a time)

Read candidates, in rough order (the notes in `data/status.csv` carry the evidence):
- `Lots.Lot_GetCellLineQuantity` - measured: 2,340 `Lots.Lot` pages to sum 2,000 pieces, about 30 ms warm. Fix: add the literal `l.LotStatusId <> 4`, as in PRs 9 and 14.
- `Lots.Lot_GetLineInventorySummary` - measured: reads the whole `Lots.Lot` heap on every call, about 28 ms warm; reportedly polled every 30 s by three bindings per sidebar (not verified). Same pattern.
- `Parts.ItemLocation_ListConsumptionForLine` - same redundant-predicate fix; not polled, low priority.
- `Lots.Lot_ListByVendorLot` - no index on `VendorLotNumber`; per check-in, low priority. A small filtered index.
- `Lots.Container_ListPendingValidation` - agent finding, unverified.
- Oee shift summary: `Workorder.ProductionEvent` has no index with `ShiftId` as a key and `ufn_ShiftInputFingerprint` / `ufn_ShiftGood` scan it. Needs a decision by whoever owns those functions.

## 8. What needs a decision (do not just do it)

- **Write paths** (anything that changes LOT, container or hold state): `Assembly_CompleteTray`, `MachiningOut_Mint`, `RejectEvent_RecordByPartFifo`, `TrimOut_Record`, `DieCastLot_Open/Release/Void`, `Lot_MoveTo`, `Lot_MoveToValidated`, `Lot_Merge`, `Lot_UpdateStatus`, `Lot_CloseInline`, `Container_Complete`, `Quality.Hold_Place`, `Quality.ControlledRun_ApplyMembersInternal/Release/SyncInternal`, `Oee_EndOfShiftEntry_Submit`, `Oee_ShiftSummary_ComputeCore`. The flagged lines in the review log say what the reviewer saw. Jacques's own notes list the `Assembly_CompleteTray` FIFO source pick and `READ_COMMITTED_SNAPSHOT` as open design work, so describe a change and ask first.
- The migration numbering and the order in which the PRs merge (section 2).
- Whether `0118` has reached prod.

## 9. How far to trust the labels

- `(no changes)` is a **static read by a reviewer agent**, not a plan test and not independently re-checked, unless the note says measured. A reviewer could have missed something.
- `(flagged)` is a claim until the note says VERIFIED. Only a handful were verified by reading the code and schema.
- `(edited)` rows were measured and tested; each has a PR.
- Separately, `sql/seeds/seed_demo.sql` fails on `main` at "LOT is not ready for Machining IN". `Run-Tests.ps1` skips the demo seed, so tests are unaffected. Nobody has looked into it.

## 10. Rebuilding the checklist and the log

From this folder: `tools\Build-Checklist.ps1` rewrites `SP_REVIEW_CHECKLIST.md`; `tools\Build-ReviewLog.ps1 -Out <path>` writes the log (`notes/2026-11-13_sp-review-log.md`). To merge a new reviewer report: `tools\Merge-Results.ps1 -Report review\results\c_<name>.md` (it never overwrites an edited or complete row). Both files come from `data/status.csv` through `tools/Lib-ReviewFormat.ps1`, so their labels and counts always match.
