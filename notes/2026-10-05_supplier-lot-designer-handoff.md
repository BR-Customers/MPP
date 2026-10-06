# Supplier lot -- Designer handoff (2026-10-05)

Four existing views need a change that has to be made in Designer, not by
file edit. Spec: `docs/superpowers/specs/2026-10-05-required-supplier-lot-on-purchased-parts-design.md`.

Close and reopen Designer after `.\scan.ps1` so it has the new `AddLotBox`
view and the updated scripts before starting.

## 1. `Components/PlantFloor/LineInventoryRow` -- AddButton

`root > Slot > AddButton`, event `onActionPerformed`. Replace the whole
script with this (the body starts with a tab in the saved file; Designer
adds it):

```python
nowMs = system.date.toMillis(system.date.now())
if nowMs < (self.view.custom.busyUntil or 0):
	return
mode = self.view.params.addLotMode
if mode != "AskQty" and mode != "OneTap":
	return
# Every add goes through the popup so the supplier lot is captured. A part
# with a box quantity opens with that quantity already filled in.
boxQty = self.view.params.boxQuantity if mode == "OneTap" else None
system.perspective.openPopup("mpp-add-lot-box", "BlueRidge/Components/PlantFloor/AddLotBox", params={"itemId": self.view.params.itemId, "description": self.view.params.description, "locationId": self.view.params.locationId, "boxQuantity": boxQty}, modal=True, showCloseIcon=True)
```

Check: tapping `+ LOT` and tapping a `+2,500` style button both open the
new popup; the second opens with 2500 in Quantity.

## 2. Cutover Scan -- Tablet, Phone, Desktop

`Views/ShopFloor/_CutoverScan/{Tablet,Phone,Desktop}`, the purchased-box
form. In each:

1. Supplier lot field (bound to `session.custom.cutover.purchased.vendorLot`):
   bind `props.placeholder` to the expression

   ```
   if({session.custom.cutover.purchased.vendorLotAbsent} && len(trim({session.custom.cutover.purchased.vendorLot})) = 0, "No lot on box", "Supplier lot (required)")
   ```

2. Add a button beside it, text `No lot on box`, classes
   `pf-btn pf-btn-secondary`, `onActionPerformed` (scope Gateway):

   ```python
   BlueRidge.Cutover.Scan.setVendorLotAbsent(self.session)
   ```

Check on each: with the field blank, Add Box is refused with "Supplier lot
number is required."; after `No lot on box`, the placeholder changes and
Add Box succeeds; the new LOT's `VendorLotNumber` is `NONE`.

## After saving

Run `git diff --stat` before committing. A view saved while it was showing
live data embeds the rows; if any of the four diffs is large, clear the
runtime data and save again.

Then tell Claude the Designer edits are in, so Task 6 of the plan (making
the supplier lot unconditional on the Line Inventory path) can run.
