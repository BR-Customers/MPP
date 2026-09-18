# Parts surfaces should read by Description, not the part code

**Date:** 2026-09-15
**Status:** Noted, not implemented.
**Raised by:** Jacques — "inventory and assembly should use the description not the code",
then a screenshot of the 6MA Cam Holder Line 1 Assembly OUT terminal showing the
**Components at this cell** rail as a column of bare part numbers.

## The requirement

Plant-floor parts surfaces SHALL read **`Parts.Item.Description`**, not `PartNumber`.
**Description only** — the code is dropped from the label entirely, not demoted to a
suffix.

Operators recognise `59B Cam Holder IN #1 Casting`. They do not recognise
`12231-59B-0000`. The screenshot makes the case on its own: eight rows of
`12243-6MA -0000`, `12232-6MA -0000`, `12245-6MA -0000`, `12241-6MA -0000` differ
only in the middle digits.

Scope is **all parts dropdowns**, plus the read-only rails the screenshot pointed at.

## Where it lives

### Pickers (shared builders — one edit each reaches every screen)

| Surface | Builder | Current label |
|---|---|---|
| Inventory Manager — "Receive loose parts" | `BlueRidge.Parts.Item.getForDropdown` (`Core/…/Parts/Item/code.py:443`) | `PartNumber` |
| Receiving Dock | same helper via `view.custom.partOptions` | `PartNumber` |
| LOT Search — part filter | same helper (`Lots/Lot/code.py:1185`) | `PartNumber` |
| Assembly (Non-Serialized) — finished-good picker | `BlueRidge.Workorder.Assembly.getEligibleFinishedGoodsForDropdown` (`Core/…/Workorder/Assembly/code.py:332`) | `PartNumber - Description` |

`Inventory Manager` is an embedded component, not a page — it appears on Assembly IN,
Assembly Serialized + Non-Serialized, Machining IN and Machining OUT Split. One edit
to `getForDropdown` covers all of them.

### Read-only rails (the screenshot)

- **Components at this cell** — `AssemblyNonSerialized/view.json`, view-level
  `custom.queueByPartVertical` and `custom.queueByPartText`. Both are
  `getComponentsAtCell` + a **script transform that groups on
  `r.get("ItemPartNumber")`** and formats `"%s   %d pcs"`. The description is not
  currently in hand here — check whether `Lots.Lot_GetComponentsAtCell` returns a
  description column; if not, that is the one SQL change this needs.
- **Line-inventory popup cards** — `BlueRidge.Lots.Lot.getLineInventoryCards`
  (`Lots/Lot/code.py:518`) maps `"item": r.get("PartNumber")`.
  `Lots.Lot_GetLineInventoryByPart` **already selects both** `PartNumber` and
  `Description`, so this one is a one-word change. Note it also
  `ORDER BY i.PartNumber ASC` — re-sort by description or the list looks shuffled.

## Things to handle when this is built

1. **Scan-or-dropdown resolution must keep working.** These dropdowns are
   `allowCustomOptions: true`; a scanned barcode arrives as a raw *part-number*
   string and is resolved by `Item.getByPartNumber`. Changing the *label* must not
   touch that path — the scanner still emits the code. Verify a scan still resolves
   (`InventoryManager.receiveParts`, `ReceivingDock.createLot`, both carry the same
   `int()`-then-`getByPartNumber` ladder).

2. **Typeahead by code stops working.** With the code out of the label, an operator
   who *does* know the part number can no longer type it into the `search: true`
   dropdown to filter. If that matters, the fix is a searchable hidden key — not
   putting the code back in the label.

3. **Empty descriptions.** Fall back to `PartNumber` when `Description` is null or
   blank. A blank label is an unpickable row.

4. **Duplicate descriptions are real.** Dev already carries two rows described
   `59B Cam-Rocker Holder Set` — `1223A-59B -A0002` and `1223A-59B-A000`, one with a
   stray embedded space. Two identical labels in a picker is a mis-pick waiting to
   happen; clean the duplicate part rather than working around it in the label.

5. **Core Python + one view, no Designer risk for the builders.** Both dropdown
   builders and `getLineInventoryCards` are in
   `ignition/projects/Core/ignition/script-python/` — file-editable, then `.\scan.ps1`.
   The two `queueByPart*` transforms live inside `AssemblyNonSerialized/view.json`,
   which is an **existing** view → Designer, per the file-edit boundary.

## Not covered

Grid columns and headers on reference surfaces (LOT Detail, Genealogy, the Inventory
report, die-cast breakdowns) were not raised and are left alone — there the code *is*
the identifier being looked up. This note is about **pickers and the operator rails**.
