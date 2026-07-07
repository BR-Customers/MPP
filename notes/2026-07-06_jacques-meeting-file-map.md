# File Map — files an agent needs to work the 2026-07-06 punch list

Paths relative to repo root `C:\Users\HunterKraft\MPP`. Views are **existing** → edit in Designer per the file-edit boundary (SQL / entity scripts / named queries / tests are safe file edits). "P__"/"R__" = repeatable procs. Verify current column shapes before editing (main moved: OperationType restructure `0032/0033`, ContainerTray FG-LOT `0034`).

---

## Die Cast entry (piece-count/weight default, cavity dropdown, shift-counts card, shots/scrap, reject→cavity, refresh button, run-without-OT gate, cavity capture, no-scrollbar, Create-LOT popup spacing)
- **Views:** `ignition/projects/MPP/.../Views/ShopFloor/DieCastBody/view.json` (the entry body — most items), `.../DieCastShared/view.json`, `.../DieCastDedicated/view.json` (shell flavors; Create-LOT popup + confirm live in/near DieCastBody — locate the create-confirm popup component if it's separate).
- **Entity scripts (Core):** `.../script-python/BlueRidge/Lots/Lot/code.py` (create, `shiftShotsFromTally`, shift tally), `.../Parts/OperationTemplate/code.py` (`getActiveTemplateIdForRoute` — the OT gate), `.../Parts/Item/code.py` (MaxParts/UnitWeight defaults), `.../Workorder/RejectEvent/code.py` (reject→cavity).
- **Named queries (Core):** `lots/Lot_GetShiftCavityTally`, `workorder/RejectEvent_Record`, `parts/OperationTemplate_GetForRouteRole`.
- **Procs:** `sql/migrations/repeatable/R__Lots_Lot_Create.sql`, `R__Lots_Lot_GetShiftCavityTally.sql`, `R__Workorder_RejectEvent_Record.sql`, `R__Tools_ToolCavity_ListActiveByTool.sql` (cavity dropdown source), `R__Parts_Item_GetMaxParts.sql`, `R__Workorder_ProductionEvent_Record.sql`.
- **Tests:** `sql/tests/0022_PlantFloor_DieCast*/` (e.g. `050`), `sql/tests/0023_PlantFloor_DieCast_Deltas/`.

## Operation Templates & Routes (dropdown → Operation Category, Data-Collection column, New-Version editor switch, skinny options box)
- **View:** `ignition/projects/MPP_Config/.../Components/Parts/ItemMaster/Routes/view.json`.
- **Entity scripts (Core):** `.../Parts/RouteTemplate/code.py` (versions, New Version, broadcastStep), `.../Parts/OperationTemplate/code.py` (`getFieldSummary`, `getOperationTemplatesByType`, add a category-based getter).
- **Named queries (Core):** `parts/OperationType_ListForDropdown` (⚠️ need an **OperationCategory** dropdown NQ — likely new), `parts/OperationTemplate_List`, `parts/OperationTemplate_GetForRouteRole`, `parts/RouteStep_ListByRoute`.
- **Procs:** `R__Parts_RouteStep_*.sql` (SaveAll/ListByRoute/MoveUp/MoveDown/Remove/Update), `R__Parts_RouteTemplate_*.sql`, `R__Parts_OperationTemplate_*.sql`, plus the `OperationType`/`OperationCategory` seed/migration (`sql/migrations/versioned/0032_operation_type_expand.sql`).

## Eligibility & Config (Area+Line tiers only, exclude terminals/printers, terminal table 100-rows+search)
- **Views:** `MPP_Config/.../Components/Parts/ItemMaster/Eligibility/view.json` (eligibility editor), `MPP/.../Views/ShopFloor/TerminalSelector/view.json` (100 rows + search).
- **Entity scripts (Core):** `.../Parts/ItemLocation/code.py`, `.../Location/Terminal/code.py` (`filterForSelector`), `.../Location/Location/code.py`.
- **Named queries (Core):** `location/Location_ListForEligibilityPicker`, `location/Terminal_ListContextCells`.
- **Procs:** `R__Location_Location_ListForEligibilityPicker.sql`, `R__Parts_ItemLocation_CheckEligibility.sql`, `R__Location_Terminal_ListContextCells.sql`, `R__Location_ufn_AncestorLocationIds.sql` (the cascade). **Tests:** `sql/tests/0009_Parts_Process/050_*`.

## Trim IN / OUT (cells=terminals-not-printers, "null" under Eligible, Trim inventory IN+OUT, selectable list, destination=line, move-to-line, no-nav-to-LOT-summary, double-checkout gate, shot/scrap validation)
- **Views:** `MPP/.../Views/ShopFloor/TrimBody/view.json` (IN/OUT body — most items), `.../TrimShared/view.json`, `.../TrimDedicated/view.json`; reusable `MPP/.../Components/PlantFloor/InventoryManager/view.json` (inventory table).
- **Entity scripts (Core):** `.../Workorder/TrimOut/code.py`, `.../Lots/Lot/code.py` (`getWipQueueByLocation`, `getByName`, `moveToValidated`).
- **Named queries (Core):** `lots/Lot_GetWipQueueByLocation`, `location/Location_ListMachiningDestinations`, `location/Terminal_ListContextCells`.
- **Procs:** `R__Workorder_TrimOut_Record.sql` (shot/scrap caps, double-checkout gate, move-to-**line**), `R__Lots_Lot_GetWipQueueByLocation.sql`, `R__Location_Location_ListMachiningDestinations.sql`, `R__Lots_Lot_MoveToValidated.sql`. **Tests:** `sql/tests/0024_PlantFloor_Movement_Trim/` (e.g. `060`).

## LOT Detail (more than terminal/machine name, scrap per movement + Total-Scrap card, round date)
- **Views:** LOT Detail page (route `/shop-floor/lot-detail/:lotId` — likely `MPP/.../Views/ShopFloor/LotDetail/view.json`; **confirm exact path**) + row components `MPP/.../Components/PlantFloor/LotDetail/{HistoryRow,ParentRow,ChildRow,PauseRow}/view.json` (date-rounding + scrap fields live in `HistoryRow`).
- **Entity scripts (Core):** `.../Lots/Lot/code.py` (history/genealogy/movement reads).
- **Procs:** `R__Workorder_ProductionEvent_ListByLot.sql`, plus the LOT movement/history reads the page binds (grep `Lot_Get*History*` / `LotMovement` reads).

## Cross-cutting — remove FDS commentary from Perspective views
- **Confirmed carrying FDS text (ShopFloor):** `AssemblyNonSerialized`, `AssemblySerialized`, `AssemblyIn`, `MachiningIn`, `MachiningOutSplit` `view.json`.
- **Do a full sweep:** `Grep "FDS-\d|FDS \d|\(FDS"` across **all** `**/view.json` in both `MPP` and `MPP_Config` projects (Config-Tool views may also carry it).

---

### Files hit by many notes (touch carefully / coordinate)
- `MPP/.../ShopFloor/DieCastBody/view.json` — ~9 Die Cast items.
- `MPP/.../ShopFloor/TrimBody/view.json` — ~8 Trim items.
- `Core/.../BlueRidge/Lots/Lot/code.py` — Die Cast + Trim + LOT Detail.
- `sql/.../R__Workorder_TrimOut_Record.sql` — 3 Trim-OUT validation/gating items.
- `Core/.../BlueRidge/Parts/OperationTemplate/code.py` — Die Cast gate + Routes dropdown.

### Not yet located (agent should confirm first)
- The **Create-LOT confirm popup** view (button-spacing) — inside/near DieCastBody or a `Components/Popups/` view.
- The **LOT Detail page** shell view exact path.
- An **OperationCategory dropdown** named query — may need to be created.
