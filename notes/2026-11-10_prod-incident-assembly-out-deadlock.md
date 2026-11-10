# 2026-11-10 -- Prod incident: Assembly OUT stopped recording trays (DB pool starved by an undetected deadlock)

**Status:** line running again ~12:30 ET (floor all clear). Stopgap in place on prod. Root cause of the lock
collision NOT fixed.

## What the floor saw

- Line Inventory panel error: `root/Head/Sub` `props.text` -- *error executing script for runScript() expression:
  BlueRidge.Lots.Lot.getLineInventoryHeader*.
- Assembly OUT stopped tracking trays.

Both were symptoms. The header script only calls `lots/Lot_GetLineInventorySummary`; `Common.Db.execList`
does not catch, so the gateway's DB error surfaced on whichever binding ran first.

## What actually happened

- Gateway log from at least 11:07 ET: `Cannot get a connection, pool error Timeout waiting for idle object,
  borrowMaxWaitDuration=PT5S` and `The database connection 'MPP' is FAULTED`. Every DB caller failed: Movement
  Scan, `getLowInventoryLock`, AIM pool top-up, print-failure broadcast, Line Inventory.
- Gateway `MPP` connection: 51 connections against a pool max of 8; "active" queries started 11:07 and never
  finished. Completed queries were fast (longest ~140 ms), so this was not a slow server.
- `sys.dm_exec_requests` / `sys.dm_os_waiting_tasks` showed a **two-session deadlock SQL Server never detected**:
  - session 80 `Workorder.Assembly_CompleteTray` **v1.6** (tray close, open txn) waiting `LCK_M_IX` on page
    38557, held by
  - session 83 `Lots.Lot_GetWipQueueByLocation` v3.2 (a **parallel** plan, DOP 8, coordinator in `CXSYNC_PORT`),
    one of whose workers was waiting `LCK_M_S` on page 82781, held by 80.
  - Both pages on the same HoBT `72057594069319680` (table/index not yet identified).
  - `Lots.Lot_GetTrimStorageQueueForLine` (78, also parallel) was stuck behind 80; ~40 screen reads piled up behind
    those, starving the 8-connection pool.
  - The deadlock monitor did not resolve it because one side was a parallel query (sibling threads in
    `EXECSYNC`), so it hung for 75+ minutes instead of failing a victim in ~5 s.

## What was done (by Jacques, on prod, 2026-11-10)

1. `KILL 83` (~12:25). Cleared, then **re-formed within a minute**: 121 (`Lot_GetWipQueueByLocation`, parallel)
   vs 117 (`Assembly_CompleteTray`), both started 12:25:57. So it reproduces on ordinary tray closes, not a one-off.
2. **`ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 1`** on the prod MES database. Was `0`; server-level
   `max degree of parallelism` is `8` (unchanged). Clears the database's plan cache as a side effect.
   **Revert:** `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;`
3. `KILL 121` (the stuck read still had its pre-change parallel plan). Pool drained to 0, ~18 queries/s, floor
   all clear.

Only reads were killed. The tray-close sessions (80, 117) were left to commit.

## Facts that matter for the fix

- The 2026-11-04 bundle (super-lot + `0115`-`0117` incl. OEE) **went to prod Thursday 2026-11-05**. Session 80/117
  ran `Assembly_CompleteTray` v1.6 (stamps `Lots.Lot.ShiftId`; `0117` added `IX_Lot_ShiftId`).
  `PROJECT_STATUS.md` and the runbook's Outcome section still say "NOT deployed" -- stale.
- It ran Thu/Fri/Mon without a reported hang, so the bundle did not break things on arrival. Working theory, not
  proven: v1.6 made a reader/writer page-lock collision possible, and this morning `Lot_GetWipQueueByLocation`
  recompiled to a parallel plan (stats update / parameter sniffing), which turned a brief block into a permanent
  hang.

## Root cause (confirmed on prod 2026-11-10 afternoon)

- HoBT `72057594069319680` = **`Lots.Lot`, index_id 0, HEAP** (PK is NONCLUSTERED, `0020`). Prod volumes:
  41,174 LOTs, 2,400 open, 46,321 `LotMovement` rows -- modest, so this is plan shape, not data size.
- Both queue reads scan the heap: `Lot_GetTrimStorageQueueForLine`'s `Eligible` has **no location filter** (every
  open LOT in the plant goes through `ufn_NextPendingRouteStep`, line filter only at the end);
  `Lot_GetWipQueueByLocation` has a catch-all `(@IncludeDescendants = 1 AND ...) OR (... = 0 AND ...)`. Both
  aggregate **all** of `Lots.LotMovement` (`LastMove ... GROUP BY LotId`) per call. Enough cost to go parallel.
- Cycle: tray close inserts the new FG LOT (IX on heap page 82781) -> a parallel scan worker waits on that page
  -> a sibling worker holds S on page 38557 while stalled at the exchange -> the tray close's source-LOT
  decrement needs IX on 38557. Part of the loop runs through the exchange, so the deadlock monitor misses it.
- The insert-then-decrement shape predates `Assembly_CompleteTray` v1.6; the 11-04 bundle is **not** implicated.

## Open

- [ ] Compare Assembly OUT physical output 11:07-12:30 ET against what MES recorded; trays closed in that window
      may be missing.
- [ ] Identify the HoBT: `SELECT OBJECT_SCHEMA_NAME(p.object_id)+'.'+OBJECT_NAME(p.object_id), i.name FROM
      sys.partitions p JOIN sys.indexes i ON i.object_id=p.object_id AND i.index_id=p.index_id WHERE
      p.hobt_id = 72057594069319680;`
- [ ] Query Store: when did `Lot_GetWipQueueByLocation`'s plan go parallel? (`sys.query_store_plan.is_parallel_plan`
      / `initial_compile_start_time` for that object and `Assembly_CompleteTray`.)
- [ ] Ask the floor whether there were brief freezes Thu/Fri/Mon (separates "collision all along" from "new plan").
- [ ] Permanent fix, via a normal release: `READ_COMMITTED_SNAPSHOT` (needs a moment of exclusive DB access)
      and/or making the queue reads and the tray close take locks in a consistent order. Then decide whether
      MAXDOP stays at 1.
- [ ] Side thread: gateway `MPP` pool max is 8 and no query timeout is set, which is why one stuck query could
      freeze the plant. Review both.
- [ ] Watch for SQL error 1205 (deadlock victim) in the gateway log: with MAXDOP 1 a repeat collision should now
      fail one side in ~5 s instead of hanging. Any 1205 confirms the lock-order problem is still live.
- [ ] Fill in the 2026-11-04 runbook's Outcome section and correct `PROJECT_STATUS.md`.
