# Review report: c_Lots_01 (44 Lots procs)

Read all 44 files in full. Index facts verified by grep of `sql/migrations/versioned/`: `Lots.Lot` heap (PK_Lot nonclustered; `UQ_Lot_LotName`; `IX_Lot_ItemId`, `IX_Lot_CurrentLocationId`, `IX_Lot_ToolId` filtered ToolId NOT NULL, `IX_Lot_Active` filtered Status IN (1,2), `IX_Lot_ShiftId`, `IX_Lot_NotClosed_Location/Item` from 0118). `Lots.LotMovement` has ONLY the clustered `(LotId, MovedAt)` and PK `(Id, MovedAt)` - no index on `ToLocationId`. `LotLabel` `(LotId, PrintedAt)`, `LotNote` `(LotId, CreatedAt DESC, Id DESC)`, `PauseEvent` filtered open indexes, `LotGenealogy` clustered `(ParentLotId, EventAt)` + `(ChildLotId, EventAt)`, `LotEventLog` clustered `(LotId, LoggedAt)`, closure PK `(AncestorLotId, DescendantLotId)` + `(DescendantLotId, AncestorLotId)`.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| GenealogyRelationshipType_Get | OK | L | read; nothing to change | n/a |
| GenealogyRelationshipType_List | OK | L | read; nothing to change | n/a |
| GlobalTrace_Resolve | WATCH | L | `ShippingLabel.AimShipperId = @Search` has no index (scan); unbounded LIKE prefix expands before TOP 50 | Yes (index add / min-length is outside the proc) |
| IdentifierSequence_Next | OK | L | read; single atomic UPDATE with ROWLOCK/UPDLOCK/HOLDLOCK, nothing to change | n/a |
| LabelTemplate_GetActiveByTypeCode | OK | L | read; nothing to change | n/a |
| LabelTypeCode_Get | OK | L | read; nothing to change | n/a |
| LabelTypeCode_List | OK | L | read; nothing to change | n/a |
| LotGenealogy_RecordConsumption | OK | L | read; no SQL or Named Query caller found, nothing to change | n/a |
| LotLabel_Print | OK | L | read; nothing to change | n/a |
| LotLabel_RecordDispatch | OK | L | read; PK update, nothing to change | n/a |
| LotLabel_Reprint | OK | L | read; uses `IX_LotLabel_Lot`, nothing to change | n/a |
| LotNote_Add | OK | L | read; single insert, nothing to change | n/a |
| LotNote_ListByLot | OK | L | read; exact index match, nothing to change | n/a |
| LotOriginType_Get | OK | L | read; nothing to change | n/a |
| LotOriginType_List | OK | L | read; nothing to change | n/a |
| LotPause_GetByLocation | OK | L | read; matches filtered `IX_PauseEvent_OpenByLocation`, nothing to change | n/a |
| LotPause_GetByLot | OK | L | read; nothing to change | n/a |
| LotPause_GetCountsByLocation | OK | L | read; filtered index COUNT, nothing to change | n/a |
| LotPause_Place | OK | L | read; check-then-insert is backed by filtered unique `UQ_PauseEvent_OpenLotLocation`, nothing to change | n/a |
| LotPause_Resume | OK | L | read; benign double-resume race (no `AND ResumedAt IS NULL` on the UPDATE), cannot matter at plant volumes | n/a |
| LotStatusCode_Get | OK | L | read; nothing to change | n/a |
| LotStatusCode_List | OK | L | read; nothing to change | n/a |
| Lot_ApplyPieceCountCorrection | OK | L | read; UPDLOCK,HOLDLOCK on PK seek then write, lock order Lot -> LotAttributeChange -> audit; nothing to change | n/a |
| Lot_AssertNotBlocked | OK | L | read; PK seek, nothing to change | n/a |
| Lot_BackfillMintStamp | OK | L | read; one-off runbook backfill (0117), not on a hot path | n/a |
| Lot_ClearCrt | OK | L | read; unlocked read then PK update, idempotence guard only, nothing to change | n/a |
| Lot_CloseInline | WATCH | L | unlocked status read then UPDATE with no status guard (check-then-write) | Yes (no result set) |
| Lot_Create | WATCH | L | steps 6/6b SUM open LOTs via `LotStatusCode` join (code-table shape) for Received origin only; B6 sequence row held to commit by design | Yes |
| Lot_Get | WATCH | M | catch-all OR over `l.Id` / `l.LotName`; plan unknown | Yes |
| Lot_GetAttributeHistory | OK | L | read; every stream seeks on LotId, nothing to change | n/a |
| Lot_GetCellLineQuantity | CANDIDATE | L | `sc.Code <> N'Closed'` code-table join cannot use `IX_Lot_NotClosed_Location`; SUM seeks every LOT ever at the location | Yes |
| Lot_GetChildren | OK | L | read; clustered ParentLotId seek, nothing to change | n/a |
| Lot_GetComponentsAtCell | OK | L | already revised/reference (open PR) | n/a |
| Lot_GetGenealogyEdgeTree | OK | L | read; edge walk seeks on both keys, report-only, MAXRECURSION 100 | n/a |
| Lot_GetGenealogyTree | OK | L | read; closure seek both directions | n/a |
| Lot_GetInspectionQueueByLocation | OK | L | already revised/reference (open PR) | n/a |
| Lot_GetLatestForToolCavity | OK | L | read; no view/script caller found (only an unused Python wrapper) | n/a |
| Lot_GetLifecycle | OK | L | read; clustered LotId seek on LotEventLog | n/a |
| Lot_GetLineInventoryByPart | CANDIDATE | M | `LastArrival` CTE aggregates ALL of `LotMovement` (no ToLocationId index) + code-table status join | Yes |
| Lot_GetLineInventorySummary | CANDIDATE | M | polled every 30 s x3 bindings per sidebar; OnHand reads Lots.Lot by location via a code-table join that cannot use the 0118 filtered index | Yes |
| Lot_GetLinkedContainer | OK | L | read; unique FinishedGoodLotId seek | n/a |
| Lot_GetOpenByTool | WATCH | L | `IX_Lot_ToolId` seek then heap lookup for every LOT ever cast on the tool, status via code join | Yes |
| Lot_GetParents | OK | L | read; `IX_LotGenealogy_Child` seek | n/a |
| Lot_GetScrapEvents | OK | L | read; clustered LotId seek on RejectEvent | n/a |

---

## CANDIDATE sections

### Lots.Lot_GetLineInventorySummary (v2.0) - CANDIDATE, Risk M
Quoted (lines 120-129):
```
120    DECLARE @OnHand TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Available INT NOT NULL);
121    INSERT INTO @OnHand (ItemId, Available)
122    SELECT l.ItemId, SUM(l.InventoryAvailable)
123    FROM Lots.Lot l
124    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
125    WHERE l.CurrentLocationId IN (SELECT Id FROM @LineLocs)
126      AND l.InventoryAvailable > 0
127      AND sc.BlocksProduction = 0
128      AND sc.Code NOT IN (N'Closed', N'Open')
```
- VERIFIED: `Lots.Lot` is a heap; `IX_Lot_CurrentLocationId` carries closed LOTs (0118 header says so); `IX_Lot_Active` (0020) is filtered to status 1,2 and does not carry `InventoryAvailable`; the 0118 filtered indexes only match a query that states a literal `LotStatusId <> 4` (0118 header: "a variable or a code-table join cannot"). This query states the exclusion only through `sc.Code NOT IN (...)`, so it cannot use them.
- INFERRED (not run): optimiser seeks `IX_Lot_CurrentLocationId` for each line location and does a heap lookup per LOT ever at those locations (open and closed) to read status / InventoryAvailable. This is shape (c) of the incident, but not a full scan.
- Fix: add a redundant literal `AND l.LotStatusId <> 4` (Closed is Id 4, guarded by 0118). Rows excluded by `sc.Code NOT IN ('Closed', ...)` already exclude Id 4, so the result is identical and the optimiser can seek `IX_Lot_NotClosed_Location (CurrentLocationId) INCLUDE (LotStatusId, ItemId)`, with a lookup only for the ~tens of open LOTs. Keep the `sc` join for `BlocksProduction` / `Open`.
- Callers / frequency: `ignition/projects/MPP/.../Components/PlantFloor/LineInventory/view.json` lines 35, 208, 248 -> `getLineInventoryFooter` / `Header` / `Instances` each `runScript(..., 30000, ...)` and each calls `Lot.getLineInventorySummary` -> this proc. So 3 executions per 30 s per terminal showing the sidebar (docked via page-config; M&A terminals), plus extra on `refreshToken` bumps and gateway broadcasts. POLLED. (Python layer could share one call; out of scope for a proc revision.)

### Lots.Lot_GetLineInventoryByPart (v1.3) - CANDIDATE, Risk M
Quoted (lines 51-56, 67-75):
```
51    ;WITH LastArrival AS (
52        SELECT m.LotId, MAX(m.MovedAt) AS ArrivedAtUtc
53        FROM Lots.LotMovement m
54        WHERE m.ToLocationId = @LocationId
55        GROUP BY m.LotId
56    )
...
71    WHERE l.CurrentLocationId = @LocationId
72      AND sc.Code <> N'Closed'
73      AND l.InventoryAvailable > 0
```
- VERIFIED: `LotMovement` has no index on `ToLocationId` (grep of all versioned migrations), only clustered `(LotId, MovedAt)` over monthly partitions, so the CTE reads every partition / every row (~46k and growing) on every call, then hash-aggregates; this is shape (b). The status filter is a code-table join (shape (c)).
- INFERRED (not run): the CTE is not pushed to the per-LOT level because it is a GROUP BY over the whole table.
- Fix: replace the CTE with `OUTER APPLY (SELECT MAX(m.MovedAt) AS ArrivedAtUtc FROM Lots.LotMovement m WHERE m.LotId = l.Id AND m.ToLocationId = @LocationId) la` (seek on the clustered key per open LOT), and add the literal `l.LotStatusId <> 4`. Same rows, same ORDER BY (COALESCE(la.ArrivedAtUtc, l.CreatedAt)).
- Callers / frequency: Line Inventory popup (`InventoryManager` view via `getInventoryPopupCards` / `getLineInventoryCards`), `ReceivingDock/view.json:734` (`runScript(..., 0, ..., refreshToken)`, no poll) and the four M&A Scrap Entry dropdowns. USER-DRIVEN (popup open / refresh-token bumps), not timer polled.

### Lots.Lot_GetCellLineQuantity (v1.0) - CANDIDATE, Risk L
Quoted (lines 20-25):
```
20    SELECT ISNULL(SUM(l.PieceCount), 0) AS ExistingPieceCount
21    FROM Lots.Lot l
22    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
23    WHERE l.CurrentLocationId = @LocationId
24      AND l.ItemId = @ItemId
25      AND sc.Code <> N'Closed';
```
- VERIFIED: same code-table-join shape as (c); heap; `IX_Lot_NotClosed_Location` / `_Item` need a literal `<> 4`.
- INFERRED (not run): seeks `IX_Lot_CurrentLocationId` or `IX_Lot_ItemId` then looks up every closed LOT for that location / part. Size depends on how many closed LOTs have sat at the destination; a storage location could be large.
- Fix: replace the join with `l.LotStatusId <> 4` (no other status column used, so the `LotStatusCode` join can be dropped; equivalent rows). Same single-row result.
- Callers / frequency: `MovementScan/view.json` line 319 (on destination scan, once per move). USER-DRIVEN, low rate. Same predicate shape is repeated in `Lot_Create` 6/6b and probably `Lot_MoveToValidated` (outside this batch); worth fixing as one pattern.

---

## WATCH sections

### Lots.Lot_Get (v1.2) - WATCH, Risk M
Quoted (lines 76-77):
```
76    WHERE (@LotId IS NOT NULL AND l.Id = @LotId)
77       OR (@LotId IS NULL AND @LotName IS NOT NULL AND l.LotName = @LotName);
```
- VERIFIED: the catch-all OR shape named in the brief, over `PK_Lot (Id)` and `UQ_Lot_LotName (LotName)` on a heap. INFERRED, not run: whether the optimiser builds an index-union seek (fine) or a heap scan with a residual predicate depends on the plan cached for the first call's parameters; needs a plan check.
- Fix if the plan scans: `IF @LotId IS NOT NULL SELECT ... WHERE l.Id = @LotId; ELSE SELECT ... WHERE l.LotName = @LotName;` (same column list, still one result set per execution), or `OPTION (RECOMPILE)`.
- Callers / frequency: Named Query `lots/Lot_Get` via `BlueRidge.Lots.Lot.get/getByName/getOrEmpty`, used by ~15 views (LotDetail, MovementScan, MachiningPickScan, HoldPanel, ScrapPanel, CountPanel, GlobalTrace, InspectionEntry ...) and several Core scripts. USER-DRIVEN, but the most widely called read in the schema.

### Lots.Lot_CloseInline (v1.0) - WATCH, Risk L
Quoted (lines 29-30, 48-50):
```
29    DECLARE @Cur BIGINT = (SELECT LotStatusId FROM Lots.Lot WHERE Id = @LotId);
30    IF @Cur IS NULL OR @Cur <> @GoodStatusId
...
48    UPDATE Lots.Lot
49    SET LotStatusId = @ClosedStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
50    WHERE Id = @LotId;
```
- VERIFIED: status is read unlocked and the UPDATE has no `AND LotStatusId = @GoodStatusId`; history row then records Good -> Closed unconditionally. In `Quality.Hold_Release` the caller has already UPDATEd the same LOT (line 78) so it is protected; in `Lots.Container_Complete` (cursor, line 224-235) I did not see a lock on the tray LOT beforehand (INFERRED: a concurrent hold placed on a tray LOT could be overwritten).
- Fix: add `AND LotStatusId = @GoodStatusId` to the UPDATE and skip the history/audit when `@@ROWCOUNT = 0`, or read with `WITH (UPDLOCK)`. No result set, so unchanged.
- Frequency: once per FG tray LOT at container complete, and on hold release. Rare race.

### Lots.Lot_Create (v1.8) - WATCH, Risk L
Quoted (lines 499-505, 556-563):
```
499            DECLARE @ExistingParts INT = (
500                SELECT ISNULL(SUM(l2.PieceCount), 0)
501                FROM Lots.Lot l2
502                INNER JOIN Lots.LotStatusCode s2 ON s2.Id = l2.LotStatusId
503                WHERE l2.CurrentLocationId = @CurrentLocationId
504                  AND l2.ItemId = @ItemId
505                  AND s2.Code <> N'Closed');
```
(6b at 556-563 is the same with `BlocksProduction = 0`.)
- VERIFIED: code-table join, cannot use `IX_Lot_NotClosed_*`; these run only for `@LotOriginTypeId = Received` (lines 497, 531) before BEGIN TRAN, so they do not extend lock time. The SUM-then-INSERT cap check is not locked (two simultaneous receipts could both pass); INFERRED negligible at one receiving dock.
- Fix: add `AND l2.LotStatusId <> 4` (and `l3.` in 6b). Everything else read: lock order inside the transaction is IdentifierSequence (U/X, held to commit, B6 by design) -> Lots.Lot insert -> LotStatusHistory -> Closure -> LotMovement -> audit; consistent and it only writes its own new LOT row (the optional `@DepositToStorage` UPDATE is on that same row), so no deadlock shape with source-LOT decrements. Note the sequence row serialises every server-minted LOT create until commit; that is by design, not a defect.
- Callers: receiving, DieCastLot_Open, Lot_Split/Merge, ControlledRun_Open, Assembly_CompleteTray (reference only). Receiving rate is low.

### Lots.Lot_GetOpenByTool (v2.1) - WATCH, Risk L
Quoted (lines 75-80):
```
75    LEFT  JOIN (
76        SELECT l2.*
77        FROM Lots.Lot l2
78        INNER JOIN Lots.LotStatusCode sc2 ON sc2.Id = l2.LotStatusId AND sc2.Code = N'Open'
79        WHERE l2.ToolId = @ToolId
80    ) l ON l.ToolCavityId = tc.Id
```
- VERIFIED: only `IX_Lot_ToolId` (ToolId) can serve `ToolId = @ToolId`; the 0118 filtered indexes do not key on ToolId, so every LOT ever cast on the die is looked up in the heap to test status. `SELECT l2.*` inside a derived table is trimmed by the optimiser. INFERRED (not run): cost scales with lifetime LOTs per tool (thousands), a few ms; `ContributorCount` subquery relies on a DieCastContribution LotId index I did not verify.
- Fix, if measurement shows it matters: a new filtered index `Lots.Lot (ToolId) INCLUDE (ToolCavityId, ...) WHERE LotStatusId = <Open id>` in a versioned migration, plus a literal status predicate in the proc. Not worth doing unsolicited.
- Callers: `DieCastBody/view.json:120` (`getOpenByToolInstances`, poll 0, refreshToken) and `DieCast.getBulkOpenRowInstances`. USER-DRIVEN refresh after actions.

### Lots.GlobalTrace_Resolve (v1.1) - WATCH, Risk L
Quoted (line 142) and (line 154):
```
142        WHERE sl.AimShipperId = @Search
154        WHERE l.LotName LIKE @Search + N'%' AND l.LotName <> @Search
```
- VERIFIED: `Lots.ShippingLabel` indexes are `(ContainerId)` and a stranded-print filtered index only, no `AimShipperId` index, so branch 4 scans `ShippingLabel` on every search (grows with every container). `LotName LIKE prefix%` is sargable on `UQ_Lot_LotName`, but a short prefix matches thousands of LOTs which are all joined (Item, status, Location) and sorted before TOP 50 (INFERRED).
- Fix: an index on `ShippingLabel (AimShipperId)` (migration, no proc change), and/or a minimum prefix length in the view/script. Result set unchanged.
- Frequency: Global Trace screen search box, rare, user-driven.

---
COUNTS: OK=36 WATCH=5 CANDIDATE=3
