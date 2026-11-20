# Named pack-outs (0136) -- performance of the changed readers

**Date:** 2026-11-20. **Branch:** `sp/parts-PackOut`. **Script:** `sql/scratch/2026-11-20_packout_perf.sql`.

## How it was measured

- `MPP_MES_Bench` (5.5M LOTs, 797k containers) copied to the throwaway `MPP_MES_Bench_PO` (COPY_ONLY backup + restore). Never Dev, never prod.
- The copy was brought to the **base branch** state (`feature/scale-part-code-map` c982406b: migrations 0118-0135 + every repeatable) and measured ("before"); then `0136` + this branch's repeatables were applied and measured again ("after").
- Two By Weight terminals: `OS-66V-TC-A100-T1` (the prod 66V part, ~123k LOTs of the part) and `MA2-6MAOP-AOUT`. 20 warm calls each; logical reads from `sys.dm_exec_requests`, per-table reads from `STATISTICS IO`.
- `GetRunningPart` was also A/B'd in one batch against a copy of the base proc + base eligibility function on the same data (200 calls each, `sys.dm_exec_procedure_stats` CPU).

## Results (reads per call, warm ms)

| Proc | Terminal | Before | After |
|---|---|---|---|
| ScaleStation_GetRunningPart | 66V | 1,288 / 6.3 ms | **617** / 4.9 ms |
| | MA2 | 1,464 / 5.8 ms | **1,011** / 5.9 ms |
| ScaleStation_ListEligibleParts | 66V | 1,334 / 4.8 ms | **589** / 4.4 ms |
| | MA2 | 1,499 / 4.7 ms | **970** / 6.5 ms (noise; see A/B) |
| ContainerConfig_JudgeWeight | both | 3 / 0.1 ms | 15 / 0.1 ms |
| Assembly_GetTraysRemaining | 66V / MA2 | 17 / 107 | 27 / 117 |
| ContainerConfig_GetByItemAndMethod | both | 3 / 0.0 ms | 17 / 0.1 ms |
| Assembly_CompleteTray (rolled back) | 66V | 132,222 / 48 ms | 132,238 / 49 ms |
| | MA2 | 23,482 / 78 ms | 23,517 / 80 ms |

Same-batch A/B, `GetRunningPart` CPU per call (200 calls): **base 5.9 ms, new 5.2 ms**; reads 1,551 -> 819.

- **`Lots.Lot`, `Lots.Container`, `Lots.ContainerTray` reads unchanged** in every proc (e.g. eligibility: `Lot` 29 reads before and after). The +12 to +16 reads on the small readers are the new pack-out tables (`PackOut`, `TerminalPackOutSelection`, covering seeks).
- **No new parallelism:** every reader ran at DOP 1 before and after. `Assembly_CompleteTray` ran at DOP 8 **before as well** (the bench's server MAXDOP is 0; prod has database MAXDOP 1 since 2026-11-10) -- pre-existing, not introduced here.

## What the measuring changed

1. **First cut of `ufn_ScaleStationEligibleParts` resolved the pack-out before the DISTINCT**, once per ancestor x eligibility row: +1,180 reads on `Parts.PackOut` (MA2 1,499 -> 2,098). Fixed: resolve once per distinct finished good (`FgItem` CTE, then `CROSS APPLY ufn_ResolvePackOut`).
2. **An `EXISTS (active By Weight pack-out)` pre-filter** on those parts tipped the plan from hash joins to nested loops: reads fell but `GetRunningPart` CPU went 6.0 -> 10.3 ms. Removed (the resolver already filters); CPU then 5.2 ms vs 5.9 ms base.
3. **`ufn_ResolvePackOut` rewritten as plain joins** (no `TOP 1 ... UNION ALL ... ORDER BY`), so it stays cheap wherever it is expanded per row.

## Caveat found on the way

An ad-hoc batch with `SET ANSI_WARNINGS OFF` cannot use filtered indexes (`IX_Container_OpenByCellItemStation`, the 0118 `IX_Lot_NotClosed_*`): both old and new procs fell to scans (71k Lot reads, Container PK scans). Ignition and sqlcmd defaults are ON, so this does not affect the application -- but any future measurement must run with default SET options.

Also noted (not changed, pre-existing): the eligibility stock read intersects `IX_Lot_ItemId` with `IX_Lot_CurrentLocationId` and does ~9,200 RID lookups on the bench in both versions.

`DBCC FREEPROCCACHE` was run once by mistake during the A/B on the local dev SQL Server (clears every database's plan cache once; harmless on dev, never to be run against prod).
