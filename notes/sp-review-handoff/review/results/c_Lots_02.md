# Review: c_Lots_02 (43 procs, all read in full)

Read-only review. Index facts below were VERIFIED by grepping `sql/migrations/versioned/*.sql`. Lots.Lot indexes that exist: `IX_Lot_ItemId`, `IX_Lot_CurrentLocationId`, `IX_Lot_ToolId` (filtered `ToolId IS NOT NULL`), `IX_Lot_Active` (filtered status 1,2), `IX_Lot_ShiftId` (0117), `IX_Lot_NotClosed_Location/_Item` (0118), plus `UQ_Lot_LotName` and nonclustered `PK_Lot`. There is NO index on `CreatedAtTerminalId`, `VendorLotNumber`, `ParentLotId`, `CreatedAt`. RCSI/snapshot isolation is not enabled anywhere in `sql/` (grep found nothing), so reads take S locks.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| Lot_GetScrapSummary | OK | L | read; nothing to change (RejectEvent (LotId,RecordedAt) and ProductionEvent (LotId,EventAt) indexes exist) | n/a |
| Lot_GetScrappablePartsByLocation | WATCH | L | `sc.Code = N'Good'` via code-table join cannot use the 0118 filtered index, so seek on `IX_Lot_CurrentLocationId` also walks every closed LOT at the cell | yes |
| Lot_GetShiftCavityTally | WATCH | M | polled every 20 s per die-cast terminal (x several bindings); per-tool LOT read has no covering index, so heap lookups for every LOT ever made on the die | yes |
| Lot_GetShippedContainers | OK | L | read; recursive walk seeded per LOT over indexed LotGenealogy, on-demand report | n/a |
| Lot_GetTerminalRecentCreations | CANDIDATE | M | polled every 20 s per die-cast terminal; no index on `CreatedAtTerminalId`, so scans die-cast LOTs/heap + sorts for TOP N | yes (index only) |
| Lot_GetTrimStorageQueueForLine | OK | L | already revised/reference | n/a |
| Lot_GetWipQueueByLocation | OK | L | already revised/reference | n/a |
| Lot_List | OK | L | read; catch-all OR shape but no view/script caller found (only `BlueRidge.Lots.Lot.list`, unreferenced) | n/a |
| Lot_ListByVendorLot | CANDIDATE | L | equality on `VendorLotNumber` with no index: full Lots.Lot heap scan on every receiving check-in | yes (index only) |
| Lot_Merge | WATCH | L | pre-txn status/piece-count read never re-checked; source-close UPDATE has no status predicate or rowcount check; no caller outside tests | yes (non-race path) |
| Lot_MoveTo | WATCH | L | check-then-write: pre-txn read of status/location, UPDATE unguarded, stale `FromLocationId` can be written to LotMovement | yes (non-race path) |
| Lot_MoveToValidated | WATCH | L | same unguarded UPDATE as MoveTo, plus MaxParts SUM via code-table join and check-then-write cap race | yes (non-race path) |
| Lot_RectifyPieceCount | OK | L | read; delegates to `Lot_ApplyPieceCountCorrection` under UPDLOCK/HOLDLOCK with expected-count re-check | n/a |
| Lot_Search | WATCH | L | catch-all OR + `LIKE '%q%'` + `COUNT(*) OVER()` + per-row OUTER APPLY into ProductionEvent over the whole heap; user-initiated only | yes |
| Lot_SearchAdvanced | WATCH | M | 12-way catch-all OR (incl. recursive CTE + EXISTS arms) with no OPTION(RECOMPILE); heap scan shape; user-initiated (LotSearch screen) | yes |
| Lot_SetCrt | OK | L | read; idempotent flag set, single-row | n/a |
| Lot_Split | OK | L | read; re-reads parent under UPDLOCK,HOLDLOCK in-txn and re-validates; name probe can use `UQ_Lot_LotName`; no caller outside tests | n/a |
| Lot_Update | OK | L | read; no named query / caller outside tests (note: sets `InventoryAvailable = @PieceCount`, would be a lost-update shape if ever wired up) | n/a |
| Lot_UpdateAttribute | OK | L | read; same as Lot_Update (no caller outside tests; "Phase 2 simplification" overwrite of InventoryAvailable) | n/a |
| Lot_UpdateStatus | WATCH | L | check-then-write: UPDATE has no `LotStatusId = @CurrentStatusId` guard, so a hold placed in the gap is overwritten Hold->Closed | yes (non-race path) |
| PrintReasonCode_Get | OK | L | read; nothing to change | n/a |
| PrintReasonCode_List | OK | L | read; nothing to change | n/a |
| SerializedPart_GetBySerial | OK | L | read; nothing to change (unique index on SerialNumber) | n/a |
| SerializedPart_GetTraceDetail | OK | L | read; nothing to change (all joins/applies hit indexed keys) | n/a |
| SerializedPart_Mint | OK | L | read; duplicate-serial pre-check is backed by `UQ_SerializedPart_SerialNumber`, sequence row locked UPDLOCK for a short txn | n/a |
| ShippingLabel_AckBanner | OK | L | read; nothing to change | n/a |
| ShippingLabel_GetById | OK | L | read; nothing to change | n/a |
| ShippingLabel_GetContainerId | OK | L | read; nothing to change | n/a |
| ShippingLabel_GetForBanner | CANDIDATE | L | polled every ~5 s by a gateway timer; no index on the predicate, so it scans the whole ShippingLabel table (rows carry `ZplContent NVARCHAR(MAX)`) | yes (index only) |
| ShippingLabel_GetLastForTerminal | OK | L | read; per button click, no terminal index but small table | n/a |
| ShippingLabel_GetStranded | OK | L | read; predicate matches filtered `IX_ShippingLabel_Stranded` exactly, runs every ~5 min | n/a |
| ShippingLabel_ListRecentByCell | OK | L | read; popup-open only, container-by-location then label by ContainerId index | n/a |
| ShippingLabel_MarkDispatch | OK | L | read; single-row update | n/a |
| ShippingLabel_RecordDispatch | OK | L | read; single-row update | n/a |
| ShippingLabel_Reprint | OK | L | read; one insert, one scalar function call | n/a |
| ShippingLabel_Void | OK | L | read; single-row update | n/a |
| SortCage_MigrateSerial | OK | L | read; rare manual op, unlocked pre-read is benign at this frequency | n/a |
| VendorReturn_Cancel | OK | L | read; UPDLOCK/HOLDLOCK on Lot, guarded UPDATEs with rowcount checks routed to CATCH | n/a |
| VendorReturn_Confirm | OK | L | read; guarded UPDATE with rowcount check | n/a |
| VendorReturn_GetEligibility | OK | L | read; nothing to change | n/a |
| VendorReturn_ListByLot | OK | L | read; `IX_VendorReturn_Lot` seek | n/a |
| VendorReturn_ListOpen | OK | L | read; `IX_VendorReturn_Open` filtered index matches | n/a |
| VendorReturn_Mark | OK | L | read; UPDLOCK/HOLDLOCK + status-guarded UPDATE + TOCTOU re-check, same Lot-first lock order as Cancel | n/a |

## CANDIDATE sections

### Lot_GetTerminalRecentCreations (Risk M)
```
54    FROM Lots.Lot l
55    LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
56    WHERE l.CreatedAtTerminalId = @TerminalLocationId
57      AND l.ToolId IS NOT NULL
58    ORDER BY l.CreatedAt DESC, l.Id DESC;      (SELECT TOP (@TopN) ...)
```
- VERIFIED: no index on `CreatedAtTerminalId` or `CreatedAt` exists in any migration. The only index that matches a predicate is `IX_Lot_ToolId` (filtered `ToolId IS NOT NULL`), which carries neither the terminal nor the sort key. So the plan is a scan of the die-cast LOT set (index scan + heap lookup per row for the terminal column, or a heap scan) followed by a sort for TOP N. INFERRED (not run): the exact plan.
- Callers: `Lots.Lot.getTerminalRecentCreations` bound in `DieCastBody/view.json` line 152, keyed on `view.custom.refreshToken`. VERIFIED in that view (lines ~60-66) that a `now(20000)` timer bumps `refreshToken` every 20 s per open die-cast terminal, and every mutation bumps it too. So it runs every 20 s per die-cast terminal, forever, against the hot heap (page S locks, same family as the 2026-11-10 scans).
- Fix: new numbered migration, e.g. `CREATE INDEX IX_Lot_CreatedAtTerminal ON Lots.Lot (CreatedAtTerminalId, CreatedAt DESC, Id DESC) INCLUDE (LotName, PieceCount, ToolCavityId) WHERE ToolId IS NOT NULL;` The proc text can stay as is (filter predicate matches the literal `IS NOT NULL`); columns/order/rows identical.

### Lot_ListByVendorLot (Risk L)
```
56    FROM Lots.Lot l
...
67    WHERE @V IS NOT NULL
68      AND l.VendorLotNumber = @V
69    ORDER BY l.CreatedAt DESC, l.Id DESC;
```
- VERIFIED: no index on `Lots.Lot.VendorLotNumber` (grep of all migrations). Equality lookup therefore scans the heap. COUNT(*) OVER() needs all matches, fine once seek is possible.
- Caller: `Lots.Lot.findVendorLotUse` / `warnIfVendorLotUsed` (`BlueRidge/Lots/Lot/code.py` ~line 806-830), run on each received-material check-in; per box, not polled. Low frequency, but each call is a full-heap scan on the hot table for a plain equality lookup.
- Fix: `CREATE INDEX IX_Lot_VendorLotNumber ON Lots.Lot (VendorLotNumber) WHERE VendorLotNumber IS NOT NULL;` (migration). Proc unchanged, result identical.

### ShippingLabel_GetForBanner (Risk L)
```
25    FROM Lots.ShippingLabel
26    WHERE PrintFailedAt IS NOT NULL
27      AND BannerAcknowledgedAt IS NULL;
```
- VERIFIED: only `IX_ShippingLabel_Container` and `IX_ShippingLabel_Stranded` (filtered `PrintedAt IS NULL AND PrintFailedAt IS NULL`, so it cannot serve this predicate) exist. So this is a scan of the whole ShippingLabel clustered index; rows include `ZplContent NVARCHAR(MAX)` (0054), so the scan reads the label text of every historical label. Row count INFERRED (grows one row per container plus reprints; not measured).
- Caller: `PrintFailureGateway.broadcastTick()` driven by `PrintFailureBroadcastTimer` (docstring: every ~5 s, gateway scope, whole plant). It takes S locks on a table that `Container_Complete` / `Shipping label` writers insert into.
- Fix: migration adding a filtered index `CREATE INDEX IX_ShippingLabel_FailedUnacked ON Lots.ShippingLabel (Id) INCLUDE (ContainerId, TerminalLocationId, AimShipperId, LastPrintError, LastPrintErrorCondition) WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL;` No proc change; result identical.

## WATCH sections

### Lot_GetShiftCavityTally (M)
```
109    LEFT JOIN (SELECT ll.Id, ll.ToolId, ll.ToolCavityId, ll.PieceCount, ll.CreatedAt, ll.UpdatedAt, lsc.Code AS StatusCode
110               FROM Lots.Lot ll INNER JOIN Lots.LotStatusCode lsc ON lsc.Id = ll.LotStatusId) l
114           ON l.ToolCavityId = tc.Id AND l.ToolId = @ToolId
116              AND (l.StatusCode = N'Open' OR l.CreatedAt >= @ShiftStart
119                   OR (l.StatusCode NOT IN (N'Closed', N'Scrap') AND l.UpdatedAt >= @ShiftStart))
```
- VERIFIED: the only usable index is `IX_Lot_ToolId` (filtered, key `ToolId` only), so every LOT ever created on that die is fetched from the heap to test ToolCavityId/status/dates; the OR arms are residual. INFERRED: per-die LOT counts (die-cast baskets are most of the ~41k LOTs; not measured) and the actual plan.
- Callers: `shiftShotsForTool`, `shiftSumForCavity`, `shiftScrapForCavity`, `shiftGoodForTool`, `shiftScrapForTool` in `Lots/Lot/code.py` each call `getShiftCavityTally`; bound in `DieCastBody` and re-run by the 20 s `refreshToken` tick (the view comment says ~9 refreshToken-keyed bindings). So several executions per tick per terminal.
- Needs a plan/measurement before deciding. If it lands as a heap-lookup-heavy plan, a filtered covering index `(ToolId, ToolCavityId) INCLUDE (LotStatusId, PieceCount, CreatedAt, UpdatedAt) WHERE ToolId IS NOT NULL` would turn it into an index-only read; result unchanged. An alternative of collapsing the several callers into one tally read per tick is a view/script change, not SQL.

### Lot_GetScrappablePartsByLocation (L)
```
47    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
49    WHERE l.CurrentLocationId = @LocationId
50      AND sc.Code = N'Good'
```
- Same shape as defect (c) in the brief: the status test goes through the code table, so the 0118 filtered index cannot be matched; the seek lands on `IX_Lot_CurrentLocationId`, which also holds every CLOSED LOT ever at that cell (VERIFIED in 0118 header), followed by a heap lookup per row for PieceCount/InventoryAvailable. INFERRED: number of closed LOTs resident at an Assembly/Machining cell.
- Caller: ScrapEntry popup open (`getScrappableParts`, `ScrapEntry/view.json` onStartup); on demand, not polled.
- Fix if measured worth it: add the redundant `AND l.LotStatusId <> 4` (Good is never Closed, so rows are identical) so `IX_Lot_NotClosed_Location` is used. Must change in step with `Workorder.RejectEvent_RecordByPartFifo` per the header (that proc is outside this batch).

### Lot_MoveTo / Lot_MoveToValidated / Lot_UpdateStatus (L, one family)
```
Lot_MoveTo 170-177:   UPDATE Lots.Lot SET CurrentLocationId = @ToLocationId ... WHERE Id = @LotId;
                      INSERT INTO Lots.LotMovement (... FromLocationId ...) VALUES (@LotId, @FromLocationId, ...)
Lot_UpdateStatus 177-181:  UPDATE Lots.Lot SET LotStatusId = @NewLotStatusId ... WHERE Id = @LotId;
```
- VERIFIED by reading: status/location/status-code are read before `BEGIN TRANSACTION` with no lock (forced by the Msg-3915 rule), and the in-txn UPDATE has no `AND CurrentLocationId = @FromLocationId` / `AND LotStatusId = @CurrentStatusId` guard and no `@@ROWCOUNT` check. A concurrent hold or move in the gap is silently overwritten and the stale value goes into LotMovement / LotStatusHistory. The sibling procs `VendorReturn_Mark/Cancel/Confirm` already use the guarded-UPDATE + `RAISERROR` into CATCH pattern. I did NOT trace a deadlock here; lock order is Lot -> LotMovement (-> LotRework) -> audit, which does not conflict with `Assembly_CompleteTray` on a single LOT row.
- Fix (same pattern the siblings use, legal under the INSERT-EXEC rules because CATCH is the only ROLLBACK): add the guard to the UPDATE and `IF @@ROWCOUNT = 0 RAISERROR(...)`. Result set unchanged except in the race.
- Callers: `Lot_MoveTo`, `Lot_MoveToValidated` (Movement Scan, per operator scan), `Lot_UpdateStatus` (manual close). Per-event, not polled.
- Extra for Lot_MoveToValidated, MaxParts cap (only when `Item.MaxParts` is set):
```
238    SELECT ISNULL(SUM(l2.PieceCount), 0) FROM Lots.Lot l2
240    INNER JOIN Lots.LotStatusCode s2 ON s2.Id = l2.LotStatusId
241    WHERE l2.CurrentLocationId = @ToLocationId AND l2.ItemId = @ItemId AND s2.Code <> N'Closed'
```
  Code-table join again (cannot use `IX_Lot_NotClosed_Location`); `l2.LotStatusId <> 4` is the equivalent literal. Two concurrent moves into the same capped location can both pass the cap (check-then-write, INFERRED, not reproduced).

### Lot_Merge (L; no Ignition caller)
```
485   UPDATE l SET l.LotStatusId = @ClosedStatusId, ...
486   FROM Lots.Lot l INNER JOIN @Sources s ON s.LotId = l.Id;
```
- VERIFIED by reading: the "all sources Good" check (lines 228-244) and `@OutPcBig` (304) run before the txn, unlocked. The comment at 365-366 says a concurrent mutation "is a genuine race surfaced through the CATCH", but the Close UPDATE has no status predicate and no `@@ROWCOUNT = @SrcCount` check, and sources are never re-read under UPDLOCK (unlike `Lot_Split`, which does). Two overlapping merges, or a merge racing `Assembly_CompleteTray` decrementing a source, would both succeed and double-count pieces. Lock order (IdentifierSequence -> new Lot insert -> source UPDATE) matches the CompleteTray order, so no deadlock concern traced.
- No named query exists for it (checked `ignition/.../named-query/lots`), and nothing calls it except tests, so practical risk is low. Fix: re-read sources `WITH (UPDLOCK, HOLDLOCK)` in-txn and `RAISERROR` on mismatch.

### Lot_Search and Lot_SearchAdvanced (L / M)
```
Lot_Search 41:        WHERE (@Q IS NULL OR l.LotName LIKE @Q OR l.VendorLotNumber LIKE @Q OR i.PartNumber LIKE @Q) AND (@LotStatusId IS NULL OR ...) AND (@LotOriginTypeId IS NULL OR ...)
Lot_Search 27,33-40:  COUNT(*) OVER() AS TotalCount ... OUTER APPLY (SELECT TOP (1) ... Workorder.ProductionEvent pe WHERE pe.LotId = l.Id ORDER BY pe.EventAt DESC ...)
Lot_SearchAdvanced 137-162: 12 optional predicates incl. (@LocationId IS NULL OR l.CurrentLocationId IN (SELECT Id FROM Descendants)),
                      (@MachineLocationId IS NULL OR ... OR EXISTS (...)), no OPTION (RECOMPILE)
```
- This is shape (a) from the brief. VERIFIED: no OPTION(RECOMPILE) and no `LIKE` prefix form; `LIKE '%q%'` can never seek anyway. INFERRED: with a cached plan the optimizer scans the heap regardless of which filter the user supplied, and because `COUNT(*) OVER()` needs the full match set, the OUTER APPLY (ProductionEvent / DieCastContribution seeks) may run for every matching row rather than only the TOP N; whether it does depends on the plan, which I did not see.
- Callers: `Lot_Search` is only the HoldManagement bulk-hold picker (`HoldManagement/view.json` line 424, user-typed); `Lot_SearchAdvanced` is the LotSearch screen (`LotSearch/view.json` line 2523, on Search click). User-initiated, not polled; a few per minute at most. Both would be heap scans with page locks on the hot table when run.
- Needs a plan check. Cheapest change if warranted: `OPTION (RECOMPILE)` on `Lot_SearchAdvanced` (or splitting the LocationId arm) so the optimizer can use `IX_Lot_ItemId` / `IX_Lot_CurrentLocationId` / `IX_Lot_ShiftId` when those filters are supplied; result unchanged.

COUNTS: OK=32 WATCH=8 CANDIDATE=3
