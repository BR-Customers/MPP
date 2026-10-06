# Required Supplier Lot Number on Purchased-Part Check-In -- Design

**Date:** 2026-10-05
**Status:** Draft for review
**Author:** Blue Ridge Automation

## Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-10-05 | Blue Ridge | Initial design from brainstorming session with Jacques. |

## 1. Purpose

When an operator adds a box of purchased parts at a line, the supplier's lot
number is not captured today. Honda genealogy needs to reach back through the
purchased component to the supplier's lot, so the number must be entered at the
moment the box becomes a LOT.

This design makes the supplier lot number **required** on the two screens where
operators check purchased boxes in during normal running and cutover, gives the
operator a fast way to enter it (scan or type), and gives them an honest answer
when the box carries no lot number at all.

## 2. Current state

- `Lots.Lot.VendorLotNumber NVARCHAR(100) NULL` exists (migration `0020`).
- `Lots.Lot_Create` accepts `@VendorLotNumber NVARCHAR(100) = NULL` and writes it.
  The `lots/Lot_Create` named query and `BlueRidge.Lots.Lot.create()` already
  pass `vendorLotNumber` through.
- Four screens create a purchased-part LOT (origin `Received`), through five
  entry paths (the Line Inventory panel has two):

| Screen | Path into `Lot_Create` | Supplier lot today |
|---|---|---|
| Line Inventory panel, `+ LOT` (AskQty) | `AddLotQty` popup -> `Lot.checkInAndNotify` -> `checkInBox` -> `create` | Not captured |
| Line Inventory panel, `+<box qty>` (OneTap) | `LineInventoryRow` button -> `Lot.checkInAndNotify` (no popup) | Not captured |
| Cutover Scan, purchased box | `Cutover.Scan.addBox` -> `create` | Optional field |
| Inventory Manager receive form | view script -> `create` | Optional field |
| Receiving Dock | view script -> `create` | Optional field |

## 3. Decisions

| # | Decision | Chosen |
|---|---|---|
| D1 | One-tap rows | Every add opens the popup. Quantity is pre-filled with the box quantity for OneTap parts and stays editable. |
| D2 | Entry method | Scan (keyboard-wedge off the supplier label) or type on the on-screen QWERTY keyboard. |
| D3 | Scope | Required on **Line Inventory** and **Cutover Scan** only. Inventory Manager and Receiving Dock remain optional and are not changed. |
| D4 | Box with no lot number | An explicit **No lot on box** button records a fixed marker. Mandatory, but never a wall. |
| D5 | Where the rule lives | In `Lots.Lot_Create`, opt-in per caller. Not in Python, not in a binding. |

D4 follows the same reasoning as the die-cast variance disposition: a hard block
with no honest exit gets answered with an invented value, and an invented
supplier lot is worse than a recorded absence because it looks real in the
genealogy.

## 4. SQL

No versioned migration. `R__Lots_Lot_Create.sql` only.

### 4.1 New parameters

```sql
@RequireVendorLot   BIT = 0,
@VendorLotAbsent    BIT = 0,
```

Both default to off, so every existing caller and every existing test is
unaffected.

### 4.2 Behaviour

Evaluated with the other rejecting validations, **before** `BEGIN TRANSACTION`
(a rejection SELECTs the status row and RETURNs with no open transaction):

1. Normalise: `@VendorLotNumber = NULLIF(LTRIM(RTRIM(@VendorLotNumber)), N'')`.
   This applies on every call, so a whitespace-only value is stored as `NULL`
   rather than as spaces.
2. If `@VendorLotAbsent = 1`: set `@VendorLotNumber = N'NONE'`, replacing
   anything supplied.
3. If `@RequireVendorLot = 1` and `@VendorLotNumber IS NULL`: reject with
   `Status = 0`, `Message = N'Supplier lot number is required.'`.

The marker `NONE` is ASCII and is defined in the proc only. A report that needs
to distinguish "no lot on the box" from a real number compares against that
value; no screen or script carries the literal.

The failure-log parameter capture near the top of the proc includes the two new
parameters. The header gains a version line describing the change.

### 4.3 Not changed

- `Lots.Lot_Update` (supplier lot stays correctable there, as today).
- The audit Description shape for LOT creation.
- No uniqueness rule on supplier lot: many boxes legitimately share one.

### 4.4 Tests

New file `sql/tests/0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql`,
INSERT-EXEC into a temp table matching the status-row shape:

| Case | Expect |
|---|---|
| Flag off, supplier lot NULL | Created; `VendorLotNumber IS NULL` (existing behaviour preserved) |
| Flag on, supplier lot NULL | `Status = 0`, message as above, no `Lots.Lot` row added |
| Flag on, supplier lot whitespace only | Same rejection |
| Flag on, supplier lot `'  AB-123 '` | Created; stored `AB-123` |
| Flag on, `@VendorLotAbsent = 1`, no value | Created; stored `NONE` |
| Flag on, `@VendorLotAbsent = 1`, value also supplied | Created; stored `NONE` |
| Flag off, `@VendorLotAbsent = 1` | Created; stored `NONE` |

Teardown follows the Arc 2 LOT order (closure rows before LOTs). The full suite
is run afterwards and the **assertion count** compared against baseline, not
just the failure count.

## 5. Named query and entity script

- `lots/Lot_Create`: add `requireVendorLot` and `vendorLotAbsent` parameters
  (Boolean), passed to the two new proc parameters. Type stays `Query`.
- `BlueRidge.Lots.Lot.create(data, ...)`: read `data.get("requireVendorLot")`
  and `data.get("vendorLotAbsent")`, default `False`.
- `checkInBox(itemId, locationId, pieceCount, appUserId, terminalLocationId,
  vendorLotNumber=None, vendorLotAbsent=False)`: passes both and sets
  `requireVendorLot = True`. This is the Line Inventory path.
- `checkInAndNotify(...)`: gains the same two arguments and forwards them. The
  success toast reads `LOT <name> - <description> - <n> pcs - supplier lot <x>`.
- `BlueRidge.Cutover.Scan.addBox`: sets `requireVendorLot = True` and passes
  `vendorLotAbsent` from the purchased-box state.

The scripts stay inert: they carry values and a flag; the proc decides.

## 6. Line Inventory popup -- new view `Components/PlantFloor/AddLotBox`

A new view, authored as files (view.json + resource.json, scope G). `AddLotQty`
is left in place and is retired in a later cleanup once nothing opens it.

### 6.1 Params and state

Params (input): `itemId`, `description`, `locationId`, `boxQuantity` (null for
AskQty parts).

`custom`, all pre-declared with shaped defaults:

```
vendorLot: ""        absent: false       qty: ""
activeField: "lot"   busyUntil: 0
```

`onStartup` (in `events.system`) seeds `qty` from `params.boxQuantity` when it
is present.

### 6.2 Layout

One popup, one keypad area that swaps.

- Title `Add LOT`, part description beneath.
- **Supplier lot** field: shows the entered value, or `No lot on box` when
  `absent` is true. Beside it, a **No lot on box** button.
- **Quantity** field: shows the entered quantity.
- Tapping a field makes it active (highlighted). The keypad area shows the
  QWERTY `Keyboard` component when the supplier lot is active and the `Numpad`
  when quantity is active. Both are embedded with their own message name and
  routed by page-scoped handlers, per the keyboard-component pattern.
- Footer: **Cancel** and **Add `<n>` pcs**.

The popup is sized for the 800 px keyboard. No drag-and-drop, no hand-placed
keys.

### 6.3 Behaviour

- Opens with the supplier lot active, so a wedge scan lands in it. The supplier
  lot input has `deferUpdates: false` so the value is committed when a button
  reads it.
- Enter (from the scanner or the on-screen keyboard) on the supplier lot moves
  the active field to quantity.
- Typing or scanning a value clears `absent`. Pressing **No lot on box** sets
  `absent`, clears the typed value, and moves to quantity.
- **Add** is enabled only when (`vendorLot` is non-blank **or** `absent`) and
  the quantity is a positive whole number, and the 2 s double-tap guard has
  elapsed.
- Submit calls `checkInAndNotify` with the supplier lot and absent flag,
  `appUserId` from `session.custom.appUserId`, and the terminal id. On
  `Status = 1` the popup closes; on a rejection it stays open with the proc's
  message toasted, so the operator can correct and retry.
- Supplier lot length is capped at 100 characters to match the column.

The enabled-state check is a convenience so the operator sees what is missing;
the proc's rejection is the rule.

## 7. Cutover Scan

- `addBox` enforcement (section 5) takes effect as soon as the script deploys:
  a blank supplier lot is refused with the proc's message.
- `session.custom.cutover.purchased` gains `vendorLotAbsent: false` (declared in
  session props and in the script's reset shapes).
- The purchased-box form on the Tablet, Phone and Desktop views gains a **No lot
  on box** button and a required marker on the supplier lot field.

## 8. Existing-view edits (Designer handoff)

Edits to existing `view.json` files go through Designer. They are written up in
`notes/2026-10-05_supplier-lot-designer-handoff.md`:

1. **`LineInventoryRow`** -- the Add button script opens `AddLotBox` for both
   `AskQty` and `OneTap`, passing `boxQuantity`; the direct `checkInAndNotify`
   call is removed.
2. **Cutover Scan Tablet / Phone / Desktop** -- the **No lot on box** button and
   the required marker.

Until item 1 is done, the Line Inventory buttons still use the old path, which
does not send a supplier lot and is therefore refused by the proc. Item 1 and
the script change in section 5 must therefore deploy together.

## 9. Out of scope

- Inventory Manager receive form and Receiving Dock (D3).
- Validating the supplier lot against a format or a supplier master.
- Printing the supplier lot on any label.
- Back-filling supplier lots on existing LOTs.
- Report changes. The value already surfaces in `Lot_Get`, `Lot_Search` and
  `Lot_SearchAdvanced`.

## 10. Assumptions

- Line terminals have a keyboard-wedge scanner, as used for LTTs. Without one,
  entry is by on-screen keyboard only; nothing in the design depends on the
  scanner being present.
- `NONE` is acceptable as the stored marker.

## 11. Deployment note

This reaches prod as a normal release: the repeatable proc, the `Lot_Create`
named query and the two script modules from Core, and the MPP views. Core
imports first. The proc change is backward compatible on its own; the script
change is not compatible with the old `LineInventoryRow` (section 8), so the
scoped export carries them together.
