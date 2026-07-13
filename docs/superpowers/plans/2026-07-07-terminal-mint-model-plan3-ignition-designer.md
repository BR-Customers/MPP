# Terminal Mint Model — Plan 3: Ignition UI (Designer change-list)

**Do these in Designer**, not by editing `view.json` on disk (view-edit boundary: Designer's unicode-escaping + the files-vs-gateway reconciliation race make on-disk edits to existing views unreliable). The **file-safe** parts (Named Queries + entity scripts) are already done and committed; this list is only the existing-view edits that bind to them. After each save, let Designer push; the backend contracts below are live on the gateway (scan done).

## New/changed backend contracts these views bind to (already committed)

- **Queue read** `BlueRidge.Lots.Lot.getWipQueueByLocation(locationId, includeDescendants=False, operationTypeCode=None, _refreshToken=None)` → route-driven. Pass the terminal's **role** as `operationTypeCode` to get only the LOTs whose *next pending route step* is that role. Result columns changed: **`HasRenameBom` / `HasLineEvent` are GONE**; added `NextOperationTypeCode`, `NextSequenceNumber`.
- **Machining OUT mint** `BlueRidge.Workorder.Machining.mint(sourceLotId, operationTemplateId, pieceCount, producedItemId=None, appUserId=None, terminalLocationId=None)` → `{Status, Message, NewId}`. Replaces `recordSplit`. (`autoComplete` is deleted.)
- **Ranked FG** `BlueRidge.Workorder.Assembly.getEligibleFinishedGoodsForDropdown(cellLocationId)` (now ranked, recommended-first) + `getRecommendedFinishedGoodId(cellLocationId)` for the default selection.
- NQs: `workorder/MachiningOut_Mint` (new), `parts/Item_ListEligibleFinishedGoodsRanked` (new), `lots/Lot_GetWipQueueByLocation` (added `operationTypeCode` param). `workorder/MachiningOut_RecordSplit` + `MachiningOut_AutoComplete` deleted.

## View edits

### 1. `ShopFloor/MachiningOutSplit` — becomes the Machining OUT **mint** screen
- **Remove the `HasRenameBom` filter** (~line 41: `[r for r in (value or []) if not r.get("HasRenameBom")]`). Replace the queue read with the role-filtered call: `getWipQueueByLocation(<lineZoneId>, False, "MachiningOut")` — it already returns only the LOTs whose next step is the Machining-OUT consume-mint (the castings ready to mint), so no client filter is needed.
- **Remove the destination dropdown** (~line 21: `getCellsForDropdownByNamePrefix("Assembly")`) and its param. Mints are **line-resident** — there is no destination pick. The minted SubAssembly is born at the line and surfaces at the next terminal via the queue rule.
- **Rework the action** (~line 609: `recordSplit(...)`): call `BlueRidge.Workorder.Machining.mint(sourceLotId=<selected cast LotId>, operationTemplateId=<MachiningOut template Id for the part's route>, pieceCount=<operator qty>, terminalLocationId=<zone>)`. Resolve the template via `BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForRoute(itemId, "MachiningOut")` (or the existing route-role resolver). **Prefill `pieceCount`** from the part's `Item.DefaultSubLotQty` (operator-overridable) — the input LOT size is irrelevant.
- Drop the "split children" repeater/JSON builder UI; it's a single qty input now.
- (Optional) rename the view `MachiningOut` for clarity.

### 2. `ShopFloor/MachiningIn`
- Queue read (~line 23): pass the role — `getWipQueueByLocation(<lineZoneId>, False, "MachiningIn")`.
- **Remove the `HasLineEvent` filter** (~line 27): the role-filtered read already returns exactly the unworked arrivals (LOTs whose next pending step is MachiningIn); once picked, the MachiningIn ProductionEvent advances them out of this queue automatically.

### 3. `ShopFloor/AssemblyNonSerialized`
- Queue read (~line 43): pass the assembly terminal's role — `getWipQueueByLocation(<cellZoneId>, False, "AssemblyOut")` (the machined/component LOTs ready to consume).
- FG dropdown (~line 1051): already bound to `getEligibleFinishedGoodsForDropdown` — now **ranked** (recommended-first), no binding change needed.
- **Default-select the recommended FG** (~line 21 `selectedFinishedGoodItemId`): initialize it from `BlueRidge.Workorder.Assembly.getRecommendedFinishedGoodId(cellLocationId)` (on cell change / view startup) so the best-matching FG is pre-picked, operator-overridable.

### 4. `ShopFloor/AssemblyIn`
- Queue read (~line 14): `getWipQueueByLocation(<cellZoneId>, False, "AssemblyIn")`.

### 5. `ShopFloor/AssemblySerialized`
- Queue read (~line 36): pass the serialized-assembly role (`"AssemblyOut"`, matching the ASER terminal's `OperationType`). Confirm the ASER terminal's role code and use it.

### 6. `ShopFloor/TrimBody`
- Queue read (~line 28): pass the trim terminal's role (`"TrimOut"` for the trim-out queue, or `"TrimIn"` per the screen's intent). Confirm which trim role this screen serves. Trim OUT keeps its cross-area destination pick (which Machining line to deposit at) — that is a legitimate location-changing handoff, *not* an intra-line mint, so leave it.

## Verify after edits
- Any other view calling `getWipQueueByLocation` with 2 positional args still works (3rd arg defaults to `None` → returns all with `NextOperationTypeCode`), but a temp-table / result-shape reader that referenced `HasRenameBom`/`HasLineEvent` will break — repoint to `NextOperationTypeCode`.
- Grep for stragglers after: `HasRenameBom`, `HasLineEvent`, `recordSplit`, `autoComplete`, `getCellsForDropdownByNamePrefix("Assembly")`, `MachiningOut_RecordSplit`, `MachiningOut_AutoComplete` should be gone from `ignition/`.
- Run `.\scan.ps1` after Designer saves; smoke the Machining OUT mint + Assembly OUT ranked default against a demo-seeded gateway DB.
