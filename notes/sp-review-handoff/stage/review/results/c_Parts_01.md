# Review report: batch c_Parts_01 (Parts schema, second half)

All 43 files read in full. Read-only; nothing run. Verified facts come from grepping `sql/migrations/versioned/` and `ignition/`.

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| R__Parts_Item_GetMaxParts.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Item_GetPlcId.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Item_List.sql | OK | L | read; leading-wildcard LIKE on a small Item table, not worth changing | n/a |
| R__Parts_Item_ListAvailableForBom.sql | OK | L | read; nothing to change (small config table, admin screen) | n/a |
| R__Parts_Item_ListEligibleFinishedGoodsRanked.sql | CANDIDATE | M | correlated subqueries on the Lots.Lot heap filtered via `JOIN LotStatusCode ... sc.Code <> N'Closed'`, so IX_Lot_NotClosed_* cannot be used; runs per Assembly OUT view load and per PLC tray close, same cell as Assembly_CompleteTray | Yes (add literal `l.LotStatusId <> 4`, keep the rest) |
| R__Parts_Item_ListEligibleForLocation.sql | OK | L | read; Parts config tables only, nothing to change | n/a |
| R__Parts_Item_ListForCutoverLocation.sql | OK | L | read; Parts config tables only, cutover-time screen | n/a |
| R__Parts_Item_SetPlcId.sql | OK | L | read; single-row update of Parts.Item, nothing to change | n/a |
| R__Parts_Item_Update.sql | OK | L | read; single-row update of Parts.Item, validations before the transaction | n/a |
| R__Parts_OperationTemplateField_Add.sql | OK | L | read; check-then-insert, but backstopped by filtered unique index UQ_OperationTemplateField_ActiveTemplateField (0006:80); admin-only | n/a |
| R__Parts_OperationTemplateField_ListByTemplate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplateField_Remove.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplateField_SaveAll.sql | OK | L | read; check-then-insert backstopped by the same unique index; admin-only | n/a |
| R__Parts_OperationTemplateField_SetRequired.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplate_Create.sql | OK | L | read; `IF EXISTS(Code)` then insert, backstopped by UQ_OperationTemplate_Code_Version (0006:59); admin-only | n/a |
| R__Parts_OperationTemplate_CreateNewVersion.sql | OK | L | read; `MAX(VersionNumber)+1` without UPDLOCK, backstopped by UQ_OperationTemplate_Code_Version; admin-only, a double-click yields an error not a duplicate | n/a |
| R__Parts_OperationTemplate_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplate_DiscardDraft.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplate_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplate_List.sql | OK | L | read; nothing to change | n/a |
| R__Parts_OperationTemplate_Publish.sql | OK | L | read; set-based deprecate of prior version inside one transaction, admin-only | n/a |
| R__Parts_OperationTemplate_Update.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteStep_Add.sql | OK | L | read; `MAX(SequenceNumber)+1` in a transaction without locks, Draft routes only, admin-only | n/a |
| R__Parts_RouteStep_GetSequenceForItemRole.sql | OK | L | read; Parts config joins only, cutover scan | n/a |
| R__Parts_RouteStep_ListByRoute.sql | OK | L | read; per-row STRING_AGG subquery over tiny tables, admin screen | n/a |
| R__Parts_RouteStep_MoveDown.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteStep_MoveUp.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteStep_Remove.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteStep_Update.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteTemplate_Create.sql | OK | L | read; check-then-insert backstopped by UQ_RouteTemplate_Item_Version (0006:101); admin-only | n/a |
| R__Parts_RouteTemplate_CreateNewVersion.sql | OK | L | read; single-Draft guard read before the transaction and `MAX+1` inside it, unique constraint prevents duplicate versions; admin-only | n/a |
| R__Parts_RouteTemplate_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteTemplate_DiscardDraft.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteTemplate_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteTemplate_GetActiveForItem.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteTemplate_ListByItem.sql | OK | L | read; nothing to change | n/a |
| R__Parts_RouteTemplate_Publish.sql | OK | L | read; validation reads and the single-Published update are all on Parts config tables, admin-only | n/a |
| R__Parts_RouteTemplate_SaveAll.sql | OK | L | read; atomic delete/update/insert of one route's steps, admin-only | n/a |
| R__Parts_Uom_Create.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Uom_Deprecate.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Uom_Get.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Uom_List.sql | OK | L | read; nothing to change | n/a |
| R__Parts_Uom_Update.sql | OK | L | read; nothing to change | n/a |

## CANDIDATE: R__Parts_Item_ListEligibleFinishedGoodsRanked.sql (v1.1)

**Quoted lines (file line numbers):**

- 38-39: `ISNULL((SELECT SUM(l.InventoryAvailable) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @LocationId AND sc.Code <> N'Closed'), 0) AS Avail,`
- 40-42: `(SELECT MIN(m.MovedAt) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ... JOIN Lots.LotMovement m ON m.LotId = l.Id WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @LocationId AND sc.Code <> N'Closed' AND l.InventoryAvailable > 0) AS EarliestReady`
- 48-58: the repack branch repeats both subqueries (same shape) with `o.Code IN (N'Received', N'ReceivedOffsite') AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0`.

**What I verified:**

- Lots.Lot has only the plain single-column indexes `IX_Lot_ItemId (ItemId)` and `IX_Lot_CurrentLocationId (CurrentLocationId)` (0020:561-562), with no INCLUDE columns. The "Lots.Lot is a heap" fact comes from the brief.
- The 0118 filtered indexes `IX_Lot_NotClosed_Location` / `IX_Lot_NotClosed_Item` (`WHERE LotStatusId <> 4`) exist.
- The 0118 header says a filtered index cannot be matched through a code-table join, only through the literal `LotStatusId <> 4`. The reference procs (`Lot_GetWipQueueByLocation` v3.3, `Lot_GetTrimStorageQueueForLine` v2.1) use that literal.

**What I inferred (not run, no plan seen):**

- Because the status test goes through `LotStatusCode`, the optimiser can only use IX_Lot_ItemId or IX_Lot_CurrentLocationId. Each seek then does a heap RID lookup for every LOT ever recorded for that child part, or at that cell, closed ones included, to read `InventoryAvailable` and `LotStatusId`. Cost grows with all-time history, not with the open LOTs (about 2.4k of 41k in prod).
- This is the same shape as root cause (c) in the brief (open-LOT filter through a code-table join that cannot use the filtered indexes).
- Each BOM line pays for two such subqueries. A finished good with a long BOM, times every eligible FG at the cell, multiplies that.
- The two subqueries per BOM line are near-duplicates over the same LOT set (Avail, then the earliest movement among the same LOTs). They could be one pass.
- It reads Lots.Lot at the Assembly cell, the same cell and table that `Workorder.Assembly_CompleteTray` inserts into and decrements. I am only saying "same neighbourhood as the 2026-11-10 incident", not that this proc deadlocks. I did not trace its lock footprint.

**Proposed fix (result set identical):**

- Add the literal `AND l.LotStatusId <> 4` to each of the four `Lots.Lot` subqueries and keep the existing `sc.Code` / `BlocksProduction` joins and predicates. The rows are the same because Id 4 is Closed (guarded in 0118), and the literal lets the optimiser use `IX_Lot_NotClosed_Item` / `IX_Lot_NotClosed_Location` (both INCLUDE the other filter column).
- Optionally compute Avail and EarliestReady in one `OUTER APPLY` per BOM line.
- Bump the header to v1.2. Keep the repack-branch stock predicate in step with `Assembly_CompleteTray` v1.5 (CLAUDE.md says the two must change together). The added `LotStatusId <> 4` is already implied by `sc.Code NOT IN ('Closed', ...)`, so the stock predicate does not change.

**Callers and frequency (grepped `ignition/`):**

- Named query `parts/Item_ListEligibleFinishedGoodsRanked`, called from `BlueRidge.Workorder.Assembly._rankedFinishedGoods` (`Assembly/code.py:278-289`).
- That feeds `getEligibleFinishedGoodsForDropdown`. Two views bind to it with `runScript(..., 0, ...)`, a poll rate of 0, so it runs once per binding evaluation and not on a timer:
  - `AssemblyNonSerialized/view.json:1049`
  - `PrinterCard/view.json:132` (one instance per card on a screen)
- `getRecommendedFinishedGoodId` and `getDefaultFinishedGoodId` also call it on Assembly OUT screen load.
- `resolvePlcCloseContext` (`code.py:204`, via `_recommendedWithPackout`) calls it on every PLC-triggered tray close when there is no open box. That puts it directly ahead of `Assembly_CompleteTray` at the same cell.
- Estimate: every Assembly OUT terminal screen load or refresh, plus every PLC tray close. Not a terminal-refresh poll, so lower frequency than the queue reads. Terminal bindings may re-fire when `session.custom.cell.locationId` changes or the inventory-changed push occurs. I did not confirm whether the push re-evaluates these bindings.

## Notes (not findings)

- Every admin-style save-all, publish, new-version and create proc in this batch does its check or `MAX+1` read without UPDLOCK/HOLDLOCK. Each is protected by a real unique constraint or filtered unique index (verified in 0004:278, 0006:59, 0006:80, 0006:101), so a race produces a unique-violation error rather than a duplicate row. These are rare admin actions on small tables, so I left them OK.
- The two exceptions with no unique backstop are RouteStep_Add's `MAX(SequenceNumber)+1` and RouteTemplate_CreateNewVersion's "single Draft per Item" guard (an `IF EXISTS` before the transaction). I did not check whether RouteStep has a unique constraint on (RouteTemplateId, SequenceNumber). Worst case under a double-click is a duplicate sequence number or a second Draft on a config table. Not worth a change at this volume.
- `Parts.Item_ListForCutoverLocation` and `Parts.Item_ListEligibleForLocation` read only Parts and Location tables (the view `Parts.v_EffectiveItemLocation` and the inline TVF `Location.ufn_AncestorLocationIds`, a recursive CTE over a roughly 5-tier tree). Nothing touches Lots.*.

COUNTS: OK=42 WATCH=0 CANDIDATE=1
