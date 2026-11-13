# Review report: c_Parts_00 (Parts schema, 46 procs)

All 46 files read in full. Method: read each proc, then grepped `sql/migrations/versioned` for the indexes and unique constraints they depend on, and `ignition/` for callers.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| R__Parts_BomLine_Add.sql | OK | L | read; nothing to change (MAX+1 SortOrder and IF EXISTS are backstopped by UQ_BomLine_Bom_ChildItem; admin screen) | n/a |
| R__Parts_BomLine_ListByBom.sql | OK | L | read; nothing to change | n/a |
| R__Parts_BomLine_MoveDown.sql | OK | L | read; nothing to change | n/a |
| R__Parts_BomLine_MoveUp.sql | OK | L | read; nothing to change | n/a |
| R__Parts_BomLine_Remove.sql | OK | L | read; nothing to change | n/a |
| R__Parts_BomLine_Update.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Bom_Create.sql | OK | L | read; nothing to change (check-then-insert backstopped by UQ_Bom_Parent_Version; CATCH maps 2601/2627) | n/a |
| R__Parts_Bom_CreateNewVersion.sql | OK | L | read; MAX(VersionNumber)+1 has no HOLDLOCK but UQ_Bom_Parent_Version + UX_Bom_ActiveDraft backstop it and CATCH maps 2601/2627 to a friendly message; single-engineer config screen | n/a |
| R__Parts_Bom_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Bom_DiscardDraft.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Bom_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Bom_GetActiveForItem.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Bom_ListByParentItem.sql | OK | L | read; per-row COUNT subquery is on a tiny table, keyed by IX_BomLine_BomId | n/a |
| R__Parts_Bom_Publish.sql | OK | L | read; auto-deprecate + publish in one txn; single-Published invariant has no unique index but publish is an engineer action on a tiny table | n/a |
| R__Parts_Bom_SaveDraft.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Bom_WhereUsedByChildItem.sql | OK | L | read; seeks IX_BomLine_ChildItemId | n/a |
| R__Parts_ContainerConfig_Create.sql | OK | L | read; backstopped by UQ_ContainerConfig_ActiveItemMethod | n/a |
| R__Parts_ContainerConfig_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ContainerConfig_GetByItem.sql | OK | L | read; nothing to change (ORDER BY scalar subquery on a 3-row code table) | n/a |
| R__Parts_ContainerConfig_GetByItemAndMethod.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ContainerConfig_JudgeWeight.sql | OK | L | read; single-row seek on ContainerConfig, no other table touched | n/a |
| R__Parts_ContainerConfig_ListHistory.sql | OK | L | read; reads Audit.ConfigLog but per ContainerConfig Id; IX_ConfigLog_EntityType (LogEntityTypeId, EntityId, LoggedAt) exists (0001) and ConfigLog is not partitioned; TOP 30; called once per Pack-Out popup open | n/a |
| R__Parts_ContainerConfig_Update.sql | OK | L | read; nothing to change | n/a |
| R__Parts_DataCollectionField_Create.sql | OK | L | read; nothing to change (UQ_DataCollectionField_Code backstop) | n/a |
| R__Parts_DataCollectionField_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_DataCollectionField_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_DataCollectionField_List.sql | OK | L | read; nothing to change | n/a |
| R__Parts_DataCollectionField_Update.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemLocation_Add.sql | OK | L | read; TOP 1 read then insert without UPDLOCK, but UQ_ItemLocation_ActiveItemLocation backstops; Config Tool only | n/a |
| R__Parts_ItemLocation_CheckEligibility.sql | OK | L | read; v_EffectiveItemLocation (ItemLocation UNION ALL BomLine/Bom/ItemLocation) filtered by ItemId and a 5-row ancestor chain; all tables tiny, IX_BomLine_ChildItemId / IX_ItemLocation_ItemId exist; fired once per Movement Scan item/destination change, not polled | n/a |
| R__Parts_ItemLocation_ListByItem.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemLocation_ListByLocation.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemLocation_ListConsumptionForLine.sql | WATCH | L | reads Lots.Lot by `CurrentLocationId IN (@LineLocs)` with the open-LOT filter expressed through a code-table join, so it cannot match IX_Lot_NotClosed_Location (same shape as incident cause (c)); popup-open frequency only | Yes |
| R__Parts_ItemLocation_Remove.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemLocation_SaveAllForItem.sql | OK | L | read; set-based reconcile, one item at a time | n/a |
| R__Parts_ItemLocation_SetConsumptionMetadata.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemLocation_SetMaxQuantity.sql | OK | L | read; single-row update, operator popup save, no Lots.* touched | n/a |
| R__Parts_ItemType_Create.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemType_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemType_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemType_List.sql | OK | L | read; nothing to change | n/a |
| R__Parts_ItemType_Update.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Item_Create.sql | OK | L | read; nothing to change (UQ_Item_PartNumber backstop) | n/a |
| R__Parts_Item_Deprecate.sql | OK | L | read; one `COUNT(*)` over Lots.Lot by ItemId (via sp_executesql, before BEGIN TRANSACTION) is a seek on IX_Lot_ItemId plus lookups, once per rare admin deprecation, so it cannot matter; WHILE loops are over a handful of cascade ids | n/a |
| R__Parts_Item_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Item_GetByPartNumber.sql | OK | L | read; seeks UQ_Item_PartNumber | n/a |

## WATCH: Parts.ItemLocation_ListConsumptionForLine (v1.1)

Quoted lines (R__Parts_ItemLocation_ListConsumptionForLine.sql):

```
121    DECLARE @OnHand TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Available INT NOT NULL);
122    INSERT INTO @OnHand (ItemId, Available)
123    SELECT l.ItemId, SUM(l.InventoryAvailable)
124    FROM Lots.Lot l
125    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
126    WHERE l.CurrentLocationId IN (SELECT Id FROM @LineLocs)
127      AND l.InventoryAvailable > 0
128      AND sc.BlocksProduction = 0
129      AND sc.Code NOT IN (N'Closed', N'Open')
130    GROUP BY l.ItemId;
```

VERIFIED:
- Lots.Lot is a heap with the unfiltered `IX_Lot_CurrentLocationId` (0020:562), which carries every closed LOT ever recorded at a location.
- Migration 0118 added `IX_Lot_NotClosed_Location (CurrentLocationId) INCLUDE (LotStatusId, ItemId) WHERE LotStatusId <> 4`. Its header says the optimiser only matches the filter when the query repeats the literal `LotStatusId <> 4`; a code-table join or a variable cannot match it. 0118 also guards that `LotStatusCode` Id 4 = `Closed`.
- This proc excludes Closed only through `sc.Code NOT IN (N'Closed', ...)`, so it cannot use the filtered index.
- `@LineLocs` is a table variable. It is estimated at 1 row, and the IN list becomes a join against it.
- `R__Lots_Lot_GetLineInventorySummary.sql` (v2.0, not in this batch) is the proc this one copies verbatim ("source of truth" comments at lines 74, 88, 97, 107, 120). It has no `LotStatusId <> 4` literal, and I did not read it further.

INFERRED, not run: the plan is either an `IX_Lot_CurrentLocationId` seek with a lookup per closed LOT at the line's cells, or a heap scan. Both take page or row S locks on Lots.Lot data pages, so this has the same shape as the incident reads. I am not claiming a deadlock; the work is bounded by one line's locations.

Proposed fix: add the redundant literal predicate `AND l.LotStatusId <> 4` at line 126-129. `Closed` is already excluded by line 129, so the rows and columns are unchanged. The optimiser can then seek `IX_Lot_NotClosed_Location` and look up `InventoryAvailable` for the roughly 2.4k open LOTs at most. Change it together with `Lots.Lot_GetLineInventorySummary`, since the block is a deliberate copy.

Callers and frequency:
- Named query `parts/ItemLocation_ListConsumptionForLine`, wrapped by `BlueRidge.Parts.ItemLocation.listConsumptionForLine` / `getToleranceInstances`.
- Only consumer is the plant-floor `Components/PlantFloor/LineTolerances` popup. It re-runs on open and when a save bumps `_refreshToken`; there is no timer or poll in the view (checked `view.json`).
- That is about a handful of runs per shift per terminal, so risk is L. It is still worth fixing alongside the sidebar proc, which is probably polled.

## Notes (no verdict impact)

- `Bom_SaveDraft`'s header says duplicate ChildItemId within a BOM is allowed, but `UQ_BomLine_Bom_ChildItem` (0007:83) forbids it. A batch with duplicates would surface as a 2627 "Unexpected error". This is a correctness comment mismatch rather than performance or concurrency, so I did not rate it.
- Races checked and all backstopped by unique indexes: `Bom_Create`, `Bom_CreateNewVersion` (`UQ_Bom_Parent_Version`, `UX_Bom_ActiveDraft` 0016), `BomLine_Add` (`UQ_BomLine_Bom_ChildItem`), `ContainerConfig_Create` (`UQ_ContainerConfig_ActiveItemMethod` 0040), `ItemLocation_Add` (`UQ_ItemLocation_ActiveItemLocation` 0006), `Item_Create` (`UQ_Item_PartNumber`), `DataCollectionField_Create` and `ItemType_Create` (`UQ_*_Code`). None of these procs touch `Lots.Lot` together with `LotMovement`, `ProductionEvent` or `Container*`, so there is no deadlock-ordering concern in this batch.

COUNTS: OK=45 WATCH=1 CANDIDATE=0
