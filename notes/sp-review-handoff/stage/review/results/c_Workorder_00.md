# Review report: c_Workorder_00 (48 Workorder procs, read in full)

Reviewer notes. Read-only; nothing run. Facts I VERIFIED in `sql/migrations/versioned/`:
- `Lots.Lot` indexes (0020/0117/0118): `IX_Lot_ItemId(ItemId)`, `IX_Lot_CurrentLocationId(CurrentLocationId)`, `IX_Lot_ToolId(ToolId) WHERE ToolId IS NOT NULL`, `IX_Lot_Active(CurrentLocationId, LotStatusId) WHERE LotStatusId IN (1,2)`, `IX_Lot_ShiftId`, `IX_Lot_NotClosed_Location`, `IX_Lot_NotClosed_Item` (filtered `LotStatusId <> 4`). There is NO index on `Lots.Lot(ToolCavityId)` or `(CreatedAt)`. `UQ_Lot_LotName` exists. No CHECK constraint on Lot quantities (only grep for `CK_Lot_*`: none on PieceCount/InventoryAvailable).
- `Lots.LotMovement`: only `CIX_LotMovement_LotMovedAt(LotId, MovedAt)` + PK; NO index on `ToLocationId`.
- `Lots.Container`: clustered PK on Id; only filtered indexes on OPEN rows (`ContainerStatusCodeId = 1`); NO index on `StationLocationId` for completed boxes. `Lots.ContainerTray`: `UQ_ContainerTray_Position(ContainerId, TrayPosition)`.
- `Audit.InterfaceLog`: `IX_InterfaceLog_Location_LoggedAt(LocationId, LoggedAt DESC)` (0113).
- Nothing in the repo turns on `READ_COMMITTED_SNAPSHOT` (grep), so I assume default READ COMMITTED locking reads (INFERRED, not checked on the server).

Two root-cause patterns from the 2026-11-10 incident recur in this batch:
- (b) full `Lots.LotMovement` aggregation: `MachiningOut_Mint` line 293 and `RejectEvent_RecordByPartFifo` line 309, both INSIDE the transaction.
- (c) open-LOT filtering through the `LotStatusCode` join (`sc.Code NOT IN ('Closed','Open')`), which cannot use `IX_Lot_NotClosed_*`: `Assembly_CompleteTray` (4 places), `Assembly_GetTraysRemaining`, `ufn_ScaleStationEligibleParts` (used by two procs here), `MachiningOut_Mint` (status variable). Closed LOTs keep their last `CurrentLocationId`, so `IX_Lot_CurrentLocationId` / `IX_Lot_ItemId` seeks return the whole closed history, not just the ~2.4k open rows.

## Summary table (batch order)

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| Workorder.Assembly_CompleteTray | CANDIDATE | H | Open-LOT reads via code-table join (4 sites incl. FIFO pick loop) cannot use filtered indexes; source-LOT FIFO pick is unlocked read-then-write; global `Lot` sequence lock held for whole txn | Yes |
| Workorder.Assembly_GetTraysRemaining | CANDIDATE | H | 30 s polled read; same code-table-join pattern as the incident reads | Yes |
| Workorder.Assembly_ScanIn | OK | L | read; nothing to change (unconditional Lot UPDATE after unlocked pre-read, tiny window) | n/a |
| Workorder.ConsumptionEvent_RecordWithBomCheck | OK | L | read; nothing to change | n/a |
| Workorder.DieCastCounterAnchorReason_List | OK | L | read; nothing to change | n/a |
| Workorder.DieCastCounterAnchor_Record | OK | L | read; nothing to change | n/a |
| Workorder.DieCastCredit_Write | OK | L | read; nothing to change (worker; UPDLOCK+HOLDLOCK on the Lot it writes) | n/a |
| Workorder.DieCastEntry_Restamp | OK | L | read; nothing to change | n/a |
| Workorder.DieCastReconciliationReason_List | OK | L | read; nothing to change | n/a |
| Workorder.DieCastScrap_Write | WATCH | L | die-wide path does `OUTER APPLY ... FROM Lots.Lot ... WHERE l.ToolCavityId = tc.Id` per cavity inside the txn; no index on `ToolCavityId` (heap scan per cavity) | Yes |
| Workorder.DieCastShiftOutput_Record | WATCH | L | die watermark read pre-txn with no lock then used to bump `Tools.Tool.ShotCount` (stale-delta race on concurrent submits) | Yes |
| Workorder.DieCastShiftReconciliation_GetHeader | OK | L | read; nothing to change | n/a |
| Workorder.DieCastShiftReconciliation_ListCavities | OK | L | read; nothing to change | n/a |
| Workorder.DieCastShiftReconciliation_ListEntries | OK | L | read; nothing to change | n/a |
| Workorder.DieCastShiftReconciliation_ListLots | OK | L | read; nothing to change (admin screen; `IX_Lot_ToolId` walk is lifetime-of-die but rare) | n/a |
| Workorder.DieCastShiftReconciliation_ListMoveTargets | OK | L | read; nothing to change | n/a |
| Workorder.DieCastShiftReconciliation_ListRejects | OK | L | read; nothing to change | n/a |
| Workorder.DieCastShiftReconciliation_ListShifts | OK | L | read; nothing to change (bounded by @Days) | n/a |
| Workorder.DieCastShiftReconciliation_Save | OK | L | read; nothing to change (rare supervisor txn; stale-stamp guard documented in header) | n/a |
| Workorder.DieCastShift_ListUnreconciled | OK | L | read; nothing to change (bounded by @Days) | n/a |
| Workorder.DieCastSupervisor_GetShiftContext | OK | L | read; nothing to change | n/a |
| Workorder.DieCastSupervisor_GetShiftTotals | OK | L | read; nothing to change (seeks `IX_DieCastContribution_Shift`) | n/a |
| Workorder.DieCast_GetCounterContext | OK | L | read; nothing to change | n/a |
| Workorder.DieCast_GetReleasePreview | OK | L | read; nothing to change | n/a |
| Workorder.DieCast_GetShiftOutputBreakdown | WATCH | L | `Relevant` CTE walks every LOT ever made on the die (`IX_Lot_ToolId`) with an `OR EXISTS`, plus ~7 scalar UDF calls per output row | Yes |
| Workorder.FinishedGoods_GetProducedSummary | OK | L | read; nothing to change (no caller outside one test; if ever polled it scans all `ContainerTray` rows with a catch-all OR) | n/a |
| Workorder.MachiningIn_RecordPick | OK | L | read; nothing to change (conditional claim UPDATE is the right pattern) | n/a |
| Workorder.MachiningOut_Mint | CANDIDATE | H | In-txn `GROUP BY LotId` over ALL `Lots.LotMovement` (line 293); unfiltered-index status predicates; scrap UPDATE locks the scanned LOT out of FIFO order before the walk | Yes |
| Workorder.OperationStatus_Get | OK | L | read; nothing to change | n/a |
| Workorder.OperationStatus_List | OK | L | read; nothing to change | n/a |
| Workorder.ProductionEvent_ListByLot | OK | L | read; nothing to change (clustered seek by LotId) | n/a |
| Workorder.ProductionEvent_Record | OK | L | read; nothing to change (monotonic guard read is unlocked, low impact) | n/a |
| Workorder.RejectEvent_Record | OK | L | read; nothing to change (UPDLOCK+HOLDLOCK + TOCTOU re-check, the reference pattern) | n/a |
| Workorder.RejectEvent_RecordByPartFifo | CANDIDATE | H | `Lots.Lot WITH (UPDLOCK, HOLDLOCK)` range-scan on item/location (includes closed history) plus an in-txn full-`LotMovement` aggregate: long, wide lock footprint on the same Lot rows CompleteTray inserts/decrements | Yes |
| Workorder.ScaleStation_GetPressLog | OK | L | read; nothing to change (30-day bound + `IX_InterfaceLog_Location_LoggedAt`) | n/a |
| Workorder.ScaleStation_GetRecentBoxes | WATCH | L | scans `Lots.Container` for `StationLocationId` + `CompletedAt` (only open-row filtered indexes exist); grows with every box | Yes |
| Workorder.ScaleStation_GetRunningPart | WATCH | M | runs `ufn_ScaleStationEligibleParts` (Lot reads through code-table join, per FG x BOM line) on every press / tray | Yes |
| Workorder.ScaleStation_GetShiftTally | WATCH | L | 60 s poll; scans `Lots.Container` twice (no `StationLocationId` index) then seeks trays for every historical box at the station | Yes |
| Workorder.ScaleStation_ListEligibleParts | WATCH | L | same `ufn_ScaleStationEligibleParts` stock reads as GetRunningPart; UI picker, less frequent | Yes |
| Workorder.ScrapSource_Get | OK | L | read; nothing to change | n/a |
| Workorder.ScrapSource_List | OK | L | read; nothing to change | n/a |
| Workorder.TrimCheckpoint_GetLatestForLot | OK | L | read; nothing to change | n/a |
| Workorder.TrimOut_Record | WATCH | M | guards (location, already-trimmed, piece count) are unlocked pre-txn reads; the Lot UPDATE is unconditional, so a double submit double-decrements scrap and double-moves | Yes (happy path) |
| Workorder.TrimPartial_Record | OK | L | read; nothing to change (same stale-guard shape as TrimOut but lot does not move; low) | n/a |
| Workorder.WorkOrderStatus_Get | OK | L | read; nothing to change | n/a |
| Workorder.WorkOrderStatus_List | OK | L | read; nothing to change | n/a |
| Workorder.WorkOrderType_Get | OK | L | read; nothing to change | n/a |
| Workorder.WorkOrderType_List | OK | L | read; nothing to change | n/a |

## CANDIDATE sections

### Workorder.Assembly_CompleteTray (R__Workorder_Assembly_CompleteTray.sql, v1.6)
Quoted lines:
- L251-256 (repack stock), L282-286 (short list), L494-499 (the B4 FIFO pick, run once per source LOT drawn):
  `FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.ItemId = @ChildItemId AND l.CurrentLocationId = @CellLocationId AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0 AND l.InventoryAvailable > 0 ... ORDER BY l.CreatedAt, l.Id`
- L494-512: pick is a plain `SELECT TOP 1` (no UPDLOCK), then `UPDATE Lots.Lot SET PieceCount = PieceCount - @Take ... WHERE Id = @SrcLotId` using the value read earlier, and `IF (@SrcPieceCount - @Take) = 0` closes from the stale read.
- L354-356: `Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK) WHERE s.Code = N'Lot'` is the FIRST statement of the txn and is held until COMMIT.
- Write order: L394 INSERT new `Lots.Lot` (+ history, closure, `LotMovement`), L433 Container UPDLOCK/HOLDLOCK, L474 `ContainerTray`, L510 UPDATE of the SOURCE Lot.

VERIFIED: the filtered indexes need the literal `LotStatusId <> 4` in the query (0118 header says a code-table join cannot match); `Lots.Lot` is a heap so each `IX_Lot_ItemId` / `IX_Lot_CurrentLocationId` hit is a RID lookup, and closed LOTs keep their `CurrentLocationId`, so the history of that cell/item is read on every tray. No lock hint on the pick (read). Write order (new Lot insert first, source Lot decrement later) is exactly the one the incident note describes. The sequence-row lock at the top is in the code as quoted.
INFERRED (not run): (1) under READ COMMITTED a reader holding S/page locks on source-Lot rows while this txn already owns X on the new LOT row is the incident deadlock shape; the 0118 fix removed the reads, not this ordering. (2) Because the `'Lot'` sequence lock is held for the whole txn, any stall in this txn (a blocked source-row update) also queues every other LOT-minting txn that takes the same sequence (`Lot_Create` and the die-cast mints, other batches), which would amplify a local block into a plant-wide one. Check `Lot_Create` takes the same lock before relying on this. (3) Two stations on one line (METTs A/B run the same BOM children into separate boxes, per the 0078 header) can both pick the same oldest source LOT before either updates it; the second UPDATE blocks, then applies the stale `@Take` (InventoryAvailable/PieceCount can go negative, no CHECK constraint; or the close-at-zero test misses). Window is small (microseconds between the SELECT and UPDATE), so likelihood is low, but `MachiningOut_Mint` v2.2 closes the same window with UPDLOCK+HOLDLOCK and a MIN() bound.
Proposed fix (3 independent, result set unchanged): (a) add the redundant literal `AND l.LotStatusId <> 4` next to the code-table predicates at L251, L282 and L494 so the optimizer can seek `IX_Lot_NotClosed_Item` (Closed is Id 4 and the existing predicate already excludes Closed, so rows are identical); (b) make the B4 pick `WITH (UPDLOCK, ROWLOCK)` and size `@Take` from the lock-fresh `MIN(InventoryAvailable, PieceCount)`, as `MachiningOut_Mint` does; (c) separate change, needs a measurement/deadlock graph first: lock the FIFO source rows before the new-Lot INSERT so the order matches readers and the other minter.
Callers/frequency: `BlueRidge.Workorder.Assembly` (ByCount handleTrayComplete, PLC `plcCompleteTray` for ByWeight/ByVision) = once per tray per station, the hottest write in the plant (tens to hundreds per shift across stations).

### Workorder.Assembly_GetTraysRemaining (R__Workorder_Assembly_GetTraysRemaining.sql, v1.0)
Quoted L102-111:
`CROSS APPLY ( SELECT ISNULL(SUM(l.InventoryAvailable), 0) AS Available FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId INNER JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId WHERE l.ItemId = n.ItemId AND l.CurrentLocationId = @CellLocationId AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0 AND (n.ReceivedOnly = 0 OR o.Code IN (...)) ) s`
VERIFIED: same shape as the incident reads (open-LOT test through the code-table join, cannot use `IX_Lot_NotClosed_Item`; heap RID lookups across the closed history of every purchased part). The proc header says it deliberately MIRRORS CompleteTray. No lock hints, plain read.
INFERRED: runs as a repeating binding, so it competes with CompleteTray at the same cell.
Proposed fix: add `AND l.LotStatusId <> 4` inside the CROSS APPLY (rows identical, enables the filtered-index seek). Change CompleteTray's sibling predicates in the same PR only if Jacques wants lock-step ("keep in lock-step" is in both headers); otherwise two PRs.
Callers/frequency: `BlueRidge.Workorder.Assembly.getLowInventoryLock` is bound with `runScript(..., 30000, ...)` in `Components/PlantFloor/LineInventory/view.json` (L51) and `Components/Popups/LowInventoryLock/view.json` (L28) = every 30 s per assembly terminal, continuously. That is the highest-frequency read in this batch.

### Workorder.MachiningOut_Mint (R__Workorder_MachiningOut_Mint.sql, v2.9)
Quoted lines:
- L289-299: `INSERT INTO @Queue (LotId) SELECT l.Id FROM Lots.Lot l CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns LEFT JOIN (SELECT LotId, MAX(MovedAt) AS LastMovementAt FROM Lots.LotMovement GROUP BY LotId) lm ON lm.LotId=l.Id WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId ...` (this is after `BEGIN TRANSACTION` at L245).
- L211-215, L221-226: the pre-txn `@TotalAvail` / `@SrcEligible` reads use `l.LotStatusId=@GoodStatusId` (a variable, so neither `IX_Lot_Active` nor the `<> 4` filtered indexes can be matched).
- L251-257 scrap `UPDATE Lots.Lot ... WHERE Id = @SourceLotId` runs BEFORE the FIFO walk; L343 walk takes `WITH (UPDLOCK, HOLDLOCK)` per queue row in FIFO order.
VERIFIED: pattern (b) from the incident (full `LotMovement` aggregate, no per-key filter; the table has only the `(LotId, MovedAt)` clustered index, so this is a scan of the whole table, ~46k rows in prod) and it sits inside the transaction; pattern (c) variant (status variable, not literal). `ufn_NextPendingRouteStep` is shared by 8 callers: not touched here.
INFERRED (not run): with scrap lines present, the scanned LOT's X lock (L253) is taken before the aggregate and held through it. Also, the scrap lock is acquired out of FIFO order: txn A holds X on the scanned LOT (say 5th in the queue) then walks from the 1st; txn B (a concurrent mint at the same cell) holds the 1st..4th via UPDLOCK and then needs the 5th. That is a possible deadlock cycle ("same shape as" the incident: a lock holder and a FIFO walker needing each other's rows); the code comment at L359-365 acknowledges concurrent mints. It needs scrap lines AND two near-simultaneous mints of the same part at one cell, so likelihood is low.
Proposed fix (result identical): replace the derived-table join with `OUTER APPLY (SELECT MAX(m.MovedAt) AS LastMovementAt FROM Lots.LotMovement m WHERE m.LotId = l.Id) lm` (per-LOT seek on the clustered index, the same fix as `Lot_GetWipQueueByLocation` v3.3), and add the redundant literal `l.LotStatusId <> 4` to the three `Lots.Lot` reads. Optionally move the scrap decrement to take its lock inside the walk order (separate, needs care).
Callers/frequency: `BlueRidge.Workorder.Machining` (operator Machining OUT) and `MachiningPlc` (PLC/gateway-driven), `Common.Ui` references it: once per Machining OUT completion, many per shift per line.

### Workorder.RejectEvent_RecordByPartFifo (R__Workorder_RejectEvent_RecordByPartFifo.sql, v1.2)
Quoted lines:
- L307-325: `;WITH LastArrival AS (SELECT m.LotId, MAX(m.MovedAt) FROM Lots.LotMovement m WHERE m.ToLocationId = @LocationId GROUP BY m.LotId), Stock AS (SELECT ... FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) LEFT JOIN LastArrival la ON la.LotId = l.Id WHERE l.CurrentLocationId = @LocationId AND l.ItemId = @ItemId AND l.LotStatusId = @GoodStatusId AND l.PieceCount > 0 AND l.InventoryAvailable > 0)` (inside the txn, L303).
- L279-286: the pre-txn total reads the same predicate unlocked.
VERIFIED: no index on `LotMovement(ToLocationId)`, so `LastArrival` scans the whole table (pattern b). `Lots.Lot` has no index covering (item, location, Good), so the plan seeks `IX_Lot_ItemId` or `IX_Lot_CurrentLocationId` (status is a variable so the filtered indexes do not match) and, with HOLDLOCK (serializable), takes U/key-range locks on every index entry it touches, including CLOSED history rows of that item/location; inserts into those key ranges (a CompleteTray minting a new LOT of the same part at the same line) must wait for this txn to finish, and the scan waits on any row CompleteTray holds X.
INFERRED (not run): collision with `Assembly_CompleteTray` at the same line (it inserts a Lot with the same ItemId/CurrentLocationId and decrements source Lots of other items). Same family as the 2026-11-10 incident; I did not trace a cycle, and scan order versus FIFO order may serialize them harmlessly.
Proposed fix (result identical): resolve the candidate LOT ids first without a lock (seek `IX_Lot_NotClosed_Location` with the literal `l.LotStatusId <> 4` plus the existing predicates; per-LOT `OUTER APPLY` for last arrival), then take `UPDLOCK, ROWLOCK` only on those rows by Id and re-validate the quantities under the lock (the existing TOCTOU check at L355 stays). Drop HOLDLOCK range semantics unless a test shows the plan needs it.
Callers/frequency: `BlueRidge.Workorder.RejectEvent.recordByPartFifo` / `BlueRidge.Lots.Lot` (Scrap Entry popup on Assembly + Machining terminals) = operator driven, a handful per shift per line.

## WATCH sections

### Workorder.DieCastScrap_Write (v1.0)
Quoted L80-89: `OUTER APPLY (SELECT TOP 1 l.Id AS LotId FROM Lots.Lot l INNER JOIN Lots.LotStatusCode lsc ON lsc.Id = l.LotStatusId WHERE l.ToolCavityId = tc.Id AND lsc.Code = N'Open') ol`.
VERIFIED: no index on `Lots.Lot(ToolCavityId)` (indexes listed above), so each active cavity costs a heap scan (or an `IX_Lot_ToolId` walk), once per cavity, inside the caller's txn. INFERRED: ~10 cavities x ~41k rows; cheap per call, but grows with the heap and runs while `DieCastShiftOutput_Record` holds locks. Only on the die-wide (`@DieWideJson`) path (shot-loss entry), rare.
Fix idea (result identical): first resolve open LOTs for the die via `IX_Lot_ToolId` (`WHERE l.ToolId = @ToolId`) into a table variable, then join per cavity; or add `Lots.Lot(ToolCavityId) INCLUDE (LotStatusId) WHERE ToolCavityId IS NOT NULL` in a numbered migration. Callers: `DieCastShiftOutput_Record`, `Lots.DieCastLot_Release`, `DieCastShiftReconciliation_Save` (die-wide JSON only from the live screens). Frequency: rare (shift end).

### Workorder.DieCastShiftOutput_Record (v3.3)
Quoted L371-373: `DECLARE @DieWatermark INT = Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @ResolvedCellLocationId);` (pre-txn, unlocked), then L478-483 `DECLARE @ShotDelta INT = ISNULL(@CounterReading, 0) - @DieWatermark; ... UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK) SET ShotCount = ShotCount + @ShotDelta`.
VERIFIED: the delta is computed from a pre-transaction read; the backward-reading guard also uses it. INFERRED: two terminals submitting for the same die and shift within the same window both see the same watermark and both add the full delta to die life. Only the lifetime die shot counter is affected (contributions and baskets are guarded per LOT), and the stale-stamp guard only exists on the reconciliation path. Frequency: operator entry at shift end / basket release; collisions are unlikely. Fix idea: read the watermark inside the txn after taking the `Tools.Tool` UPDLOCK (move the `UPDLOCK` read of the tool to the top of the txn).

### Workorder.DieCast_GetShiftOutputBreakdown (v3.2)
Quoted L206-215: `WITH Relevant AS (SELECT l.Id ... FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.ToolId = @ToolId AND ( sc.Code = N'Open' OR EXISTS (SELECT 1 FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id AND c.ShiftId = @ShiftId) ))`; plus L236-248, L256-262, L274 call `Workorder.ufn_CavityShotWatermark` / `ufn_CavityCreditedWithoutReading` ~7 times per output row.
VERIFIED: `IX_Lot_ToolId` has no status column, so every LOT ever cut on the die is looked up in the heap and tested; per-row scalar functions each seek `DieCastContribution` / `DieCastCounterAnchor` (those have shift-scoped indexes). INFERRED: cost grows with the die's lifetime basket count (hundreds to thousands), not shift size; scalar UDF inlining may or may not apply (not checked). Result columns/rows would be identical if `Relevant` became `Open lots` UNION `lots credited this shift` (`IX_DieCastContribution_Shift (ShiftId, LotId)`). Callers: `BlueRidge.Workorder.DieCast.getShiftOutputBreakdown` from `DieCastBody` Compute / die-wide re-proposal (operator driven). Frequency: low-moderate.

### Workorder.ScaleStation_GetRunningPart and ScaleStation_ListEligibleParts
Both call `Workorder.ufn_ScaleStationEligibleParts`, whose stock reads are (file R__Workorder_ufn_ScaleStationEligibleParts.sql, outside this batch):
`FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = fb.LineId AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0 AND l.InventoryAvailable > 0` (and a second copy for repack with the origin join), evaluated per finished good x BOM line at the terminal's line.
VERIFIED: same open-LOT-through-code-table pattern. `ScaleStationPress` path: `BlueRidge.Workorder.Assembly` (plcCompleteTray, ByWeight) calls `ScaleStation.getRunningPartOrEmpty(tid)` right before the tray is minted, and `ScaleStation/view.json` L54 binds `getRunningPartOrEmpty` with refresh 0 on `pressToken` (re-evaluates on each press). INFERRED: reads stock at the line just before `Assembly_CompleteTray` writes it. Fix belongs in the ufn (add `AND l.LotStatusId <> 4`); treat as a change to that function. ListEligibleParts is the picker (operator opens it, less frequent). Not a CANDIDATE here only because the defect is in a function outside this batch.

### Workorder.ScaleStation_GetShiftTally / ScaleStation_GetRecentBoxes
Quoted (GetShiftTally L60-72): `FROM Lots.ContainerTray ct JOIN Lots.Container c ON c.Id = ct.ContainerId WHERE c.StationLocationId = @TerminalLocationId AND ct.ClosedAt >= @FromUtc AND ct.ClosedAt < @ToUtc` and `FROM Lots.Container c WHERE c.StationLocationId = @TerminalLocationId AND c.CompletedAt >= @FromUtc AND c.CompletedAt < @ToUtc`; (GetRecentBoxes L43-65) `FROM Lots.Container c ... WHERE c.StationLocationId = @TerminalLocationId AND c.CompletedAt IS NOT NULL ORDER BY c.CompletedAt DESC`.
VERIFIED: `Lots.Container` has only filtered indexes on open boxes (0028, 0078), so completed boxes are read by a clustered scan; `ContainerTray` has no index on `ClosedAt`, so the tray time filter runs after a per-container seek for every box the station ever produced. INFERRED: cost O(boxes ever), small at today's volume (likely ~10^4 rows), grows without bound. GetShiftTally runs on a 60 s binding (`ScaleStationShiftTally/view.json` L31); GetRecentBoxes on press token. Fix idea: new migration index `Lots.Container (StationLocationId, CompletedAt) INCLUDE (...) WHERE CompletedAt IS NOT NULL` (results identical). Low urgency.

### Workorder.TrimOut_Record (v1.6)
Quoted: pre-txn guards L204-212 (read LOT), L243-258 (location), L293 (already in Trim Storage), L322-335 (counts vs `@LotPieceCount`); in-txn L386 (ProductionEvent insert), L437-440 (RejectEvent insert), L445-451 `UPDATE Lots.Lot SET CurrentLocationId = @TrimStoreId, PieceCount = PieceCount - @ScrapTotal, InventoryAvailable = InventoryAvailable - @ScrapTotal ... WHERE Id = @ParentLotId;` then L453 `LotMovement` insert.
VERIFIED: no lock on the pre-read and the UPDATE has no `AND CurrentLocationId = @FromLocationId` predicate (contrast `MachiningIn_RecordPick` L235-237, which re-asserts the location and no-ops the race loser; `RejectEvent_Record` v1.1 re-checks under UPDLOCK). INFERRED: a double submit (double tap, or a second terminal) passes every guard twice, writes two ProductionEvents/RejectEvents, subtracts scrap twice (PieceCount can go negative; no CHECK) and writes a second LotMovement. Whether the UI prevents re-entry I did not check. Fix idea (happy path identical): add `AND CurrentLocationId = @FromLocationId` to the UPDATE and check `@@ROWCOUNT` before the inserts (commit the no-op like RecordPick, never ROLLBACK in an INSERT-EXEC proc). Callers: `BlueRidge.Workorder.TrimOut`-family scripts on the Trim terminals; per LOT checked out, many per shift.

## Other observations (not verdict-changing)
- `Assembly_ScanIn` L127-131 and `MachiningIn_RecordPick` (conditional UPDATE) are the two move patterns: ScanIn does LotMovement INSERT then an unconditional Lot UPDATE; a double scan of one LOT into two cells would write two movements. RecordPick's conditional UPDATE does not protect the case `@FromLoc = @LineLocationId` (LOT already at the line, route not yet satisfied): a double pick would write two MachiningIn checkpoints. Both low.
- `Assembly_CompleteTray` non-station branch (L451-453, no `@StationLocationId`) has no UPDLOCK on the open Container and `MAX(TrayPosition)+1` (L473) is unlocked: duplicate boxes or a `UQ_ContainerTray_Position` violation (fails loudly, not silently) are possible for callers with no Terminal-type location. Station branch is correctly serialised by UPDLOCK+HOLDLOCK.
- `MachiningOut_Mint` L302 mint-name suffix (`MAX(...)+1` over `LotName LIKE`) is unlocked; a concurrent mint from the same oldest casting would collide on `UQ_Lot_LotName` (verified unique) and fail loudly, not silently.
- `FinishedGoods_GetProducedSummary` has no callers outside `sql/tests/0028_PlantFloor_Assembly/095_FinishedGoods_KPI.sql` (grepped `ignition/` and `sql/`), hence OK.

## Lock-order table for the mutation procs
Order = order in which the transaction touches each table (first to last). U = UPDLOCK, S/X = implied. "Pre" = read before `BEGIN TRANSACTION` with no lock.

| Proc | Pre-txn unlocked reads | 1st | 2nd | 3rd | 4th | 5th+ | UPDLOCK on rows it reads then writes? | Read-then-write / FIFO race |
|---|---|---|---|---|---|---|---|---|
| Assembly_CompleteTray | Lot status/stock sums (L251, L282), Container open box (L313-326), `OpenAccum` | `IdentifierSequence 'Lot'` (ROWLOCK,UPDLOCK,HOLDLOCK, held to commit) | INSERT `Lots.Lot` (new FG) -> `LotStatusHistory` -> `LotGenealogyClosure` self -> `LotMovement` -> Audit | `Lots.Container` (UPDLOCK,HOLDLOCK in station branch; plain read otherwise) / INSERT Container -> Audit | INSERT `ContainerTray` (`MAX(TrayPosition)` unlocked) | per source LOT: unlocked FIFO read -> UPDATE source `Lots.Lot` -> (UPDATE status + `LotStatusHistory`) -> INSERT `ConsumptionEvent` -> `LotGenealogy` -> `LotGenealogyClosure`; then B4b UPDATE FG Lot (CRT); Audit | Sequence row and Container: yes. Source component LOTs: NO | Yes: two stations drawing from the same oldest source LOT (stale `@Take`); low window. Non-station container path can double-open |
| MachiningOut_Mint | Source LOT, available sums, `@SrcEligible` (L140, L211-226) | (if scrap lines) UPDATE source `Lots.Lot` (+ close/`LotStatusHistory`) -> INSERT `RejectEvent` | `@Queue` build: read `Lots.Lot` + full `LotMovement` aggregate (L289-299) | INSERT `Lots.Lot` (SubAssembly) -> `LotStatusHistory` -> closure self -> `LotMovement` | per casting in FIFO order: `Lots.Lot WITH (UPDLOCK, HOLDLOCK)` -> UPDATE Lot -> (close + history) -> INSERT `ProductionEvent` -> `ConsumptionEvent` -> `LotGenealogy` -> closure | CRT UPDATE on new Lot; Audit | Yes in the walk (lock-fresh MIN bound, `@Need > 0` raises if drained). Scrap target is locked outside FIFO order (possible cycle with a concurrent mint) | Handled by the walk; mint name suffix collision fails loudly (`UQ_Lot_LotName`) |
| MachiningIn_RecordPick | Lot, route step (`ufn_NextPendingRouteStep`), eligibility, terminal | Conditional UPDATE `Lots.Lot` (`WHERE CurrentLocationId = @FromLoc`), commits a no-op if 0 rows | INSERT `LotMovement` | INSERT `ProductionEvent` | Audit | - | Conditional UPDATE instead of UPDLOCK (correct) | Race loser rejected cleanly; only gap: `@FromLoc = @LineLocationId` (see Other observations) |
| TrimOut_Record | Lot, location guards, counts, `ufn_TrimPassPreviousCount` | INSERT `ProductionEvent` | (open rework) UPDATE `Lots.LotRework` -> Audit | INSERT `RejectEvent` rows | UPDATE `Lots.Lot` (unconditional) | INSERT `LotMovement` -> Audit | NO | Yes: double submit (WATCH above) |
| TrimPartial_Record | Lot, shift, counts, previous checkpoint | INSERT `ProductionEvent` | INSERT `RejectEvent` | UPDATE `Lots.Lot` (only if scrap) | Audit | - | NO | Low: stale count guard, LOT does not move |
| RejectEvent_Record | Lot status, piece count, defect code | INSERT `RejectEvent` | UPDATE `Lots.Lot WITH (UPDLOCK, HOLDLOCK)` (subtractive only) with re-check `@NewPieceCount < 0` | (close at zero) UPDATE Lot -> `LotStatusHistory` | Audit | - | Yes (UPDLOCK,HOLDLOCK + re-check) | Guarded (reference pattern) |
| RejectEvent_RecordByPartFifo | Stock total (L279-286) | Range read `Lots.Lot WITH (UPDLOCK, HOLDLOCK)` (every candidate row for item+location) + full `LotMovement` aggregate | per (LOT, reason): INSERT `RejectEvent` | UPDATE `Lots.Lot` | Audit -> (close) UPDATE Lot, `LotStatusHistory`, Audit | - | Yes, but over a very wide range (see CANDIDATE) | Total re-checked after lock (L355) |
| Assembly_ScanIn | Lot, BOM component test, CRT | INSERT `LotMovement` | UPDATE `Lots.Lot` (unconditional) | Audit | - | - | NO | Double scan into two cells possible (low) |
| ProductionEvent_Record | Lot status, last `ProductionEvent` counters | INSERT `ProductionEvent` (+ `ProductionEventValue`) | Audit | - | - | - | NO (does not write Lot) | Monotonic guard read unlocked (low) |
| ConsumptionEvent_RecordWithBomCheck | Lots (item), BOM | INSERT `ConsumptionEvent` | Audit (override only) | - | - | - | n/a (does not decrement the source LOT) | None |
| DieCastShiftOutput_Record | Lot/cavity validation, `ufn_DieShotWatermark` | per line (cursor): `DieCastCredit_Write`: INSERT `DieCastContribution` -> UPDATE `Lots.Lot WITH (UPDLOCK, HOLDLOCK)` -> Audit | zero-delta credits (INSERT `DieCastContribution`, no Lot write) | `DieCastScrap_Write`: INSERT `RejectEvent` (die-wide path scans `Lots.Lot` per cavity) | UPDATE `Tools.Tool WITH (UPDLOCK, HOLDLOCK)` last | - | Lot: yes. Tool: yes, but the delta came from a pre-txn read | Stale watermark (WATCH above) |
| DieCastShiftReconciliation_Save | Everything is pre-computed (stamp guard, plan) | INSERT `DieCastShiftReconciliation` | `DieCastEntry_Restamp` (UPDATE `DieCastContribution`, `RejectEvent`, INSERT `DieCastReconciliationMove`) | `Lots.DieCastLot_Mint` (new Lots) -> `DieCastCredit_Write` (Contribution -> Lot UPDLOCK) -> `DieCastScrap_Write` | INSERT `DieCastCounterAnchor` -> UPDATE `Tools.Tool` UPDLOCK -> `DieCastLot_ReleaseMove` (Lot, `LotMovement`) -> `Lot_ApplyPieceCountCorrection` | UPDATE header -> Audit | Lot and Tool: yes (via workers) | Stale-stamp guard pre-txn; header documents the remaining window |
| DieCastCounterAnchor_Record | watermark | INSERT `DieCastCounterAnchor` | Audit | - | - | - | n/a | None |

Cross-proc ordering notes (INFERRED from the table, not traced): minters (`CompleteTray`) go Lot INSERT -> source Lot UPDATE; consumers (`MachiningOut_Mint`, `DieCastCredit_Write`) go Lot UPDLOCK -> event INSERT; event-writers (`TrimOut_Record`, `RejectEvent_Record`, `TrimPartial_Record`, `ProductionEvent_Record`) go event INSERT -> Lot UPDATE. Event-table inserts rarely block each other, so mixed order matters mainly when a scan/range reader (the HOLDLOCK range in `RecordByPartFifo`, or any page-lock reader) sits between them. `CompleteTray` is the only proc here that takes a plant-global lock (`IdentifierSequence 'Lot'`) first and holds it for the whole txn.

COUNTS: OK=36 WATCH=8 CANDIDATE=4
