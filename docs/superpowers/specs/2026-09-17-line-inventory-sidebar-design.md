# M&A Line Inventory Sidebar -- design

**Date:** 2026-09-17
**Status:** Design approved 2026-09-17; plan next
**Requested by:** MPP (2026-09-16)
**Mockup:** `mockup/line_inventory_sidebar_mock.html` (approved layout, 2026-09-17)
**Migration:** `0091_line_inventory_sidebar` (next free number at time of writing -- `0090` is
claimed by the OEE-enabled-locations spec; re-check before build)
**Screens:** Machining IN, Machining OUT, Assembly IN, Assembly OUT (serialized + non-serialized)

---

## 1. Problem

Operators on the Machining & Assembly lines cannot see or manage line-side stock easily, and
that gap is costing accurate accounting of their work.

- **Machining IN shows no inventory at all.** It is only reachable through the Inventory popup.
- **Assembly OUT (serialized) shows a single text label** -- `"PN: N pcs | PN: N pcs"` -- which
  is poor Ignition practice and hard to read.
- **Assembly OUT (non-serialized)** has a sidebar, but it lists part *numbers* and flags a part
  low only against the trays left in the *current container*. A part can be one container away
  from running out and show nothing.
- **The Inventory popup lists every open LOT**, finished goods included. On an assembly line
  that is mostly finished-good noise.
- **Bought parts have no quick way in.** Dowel pins arrive in 5,000-piece boxes. Checking one in
  means the full receive flow.

## 2. What we are building

One shared component, **Line Inventory**. It is a tall, 320px-wide panel docked on the right
of all five M&A screens. It lists the line's parts, one compact row each:

| Row element | Rule |
|---|---|
| **Description** | `Parts.Item.Description`, never the part number. Wraps to two lines, then clips. |
| **Available** | Sum of `Lot.InventoryAvailable` over the line's open LOTs of that part. |
| **Button** | Only on **PassThrough** parts (the bought parts -- see § 3.1). |
| **Low** | Whole row tinted light orange with a bright orange border. No badge, no shortfall number. |

**Order:** low rows first, then alphabetical by description.

**Density:** rows are 40px with 4px gaps and ~28px buttons, so **12 rows fit with no scrolling**
on a terminal. Jacques's bar is "8-10 rows on a screen, no scrolling"; that is a hard
requirement, not a nicety.

**Finished goods are never listed.**

## 3. Rules

### 3.1 Which parts get a button

Migration `0089` (in prod since 2026-09-16) retyped the 33 bought parts from `Component` to
`PassThrough`, per FDS-03-002 (`Component` = manufactured intermediate, `PassThrough` =
vendor-supplied). So "purchased" is now simply **`ItemType = PassThrough`**.

| Item type | Button | What one press does |
|---|---|---|
| PassThrough, **Box Quantity set** | `+5,000` (the box size) | One tap: creates one `Received` LOT of Box Quantity pieces. |
| PassThrough, **no Box Quantity** | `+ LOT` | Opens the plant-floor numpad for a count, then creates one `Received` LOT. |
| Component, SubAssembly, RawMaterial | none | Made parts arrive on their own route. |
| FinishedGood | -- | Never listed. |

The mode is decided in SQL and returned as `AddLotMode` (`OneTap` / `AskQty` / `None`), per the
no-business-logic-in-Python rule. The view only renders what it is told.

**One LOT per box.** Each press is its own LOT (per-box genealogy), attributed to the signed-in
operator. No vendor lot is captured.

### 3.2 When a part is low

1. **Finished-good setting.** New `Parts.Item.LowInventoryHorizon INT NULL`, set per finished
   good in Item Master (MPP's intent: 50). It means "warn me when the line can't build this many
   more".
2. **Running finished good(s).** The line's running finished goods are:
   - the item of every **open** `Lots.Container` at any location under the line; plus
   - the finished good the Assembly OUT screen has selected
     (`view.custom.selectedFinishedGoodItemId`), passed in as an optional hint, so a line that
     has chosen its part but not yet opened a container still gets warnings.
3. **Requirement per part.** For each running finished good that has a horizon, walk its active
   BOM tree:
   - A BOM is active when `PublishedAt IS NOT NULL AND DeprecatedAt IS NULL`, taking the highest
     `VersionNumber`.
   - Multiply `QtyPer` down the levels, so a casting under a SubAssembly counts
     `casting-per-SA x SA-per-FG` per finished good.
   - `Threshold = CEILING(rolled QtyPer x LowInventoryHorizon)`.
   - When two running finished goods need the same part, take the **larger** threshold.
4. **Low** = `Available < Threshold`.
5. **No low flag** when the line has no running finished good, or none of them has a horizon.
   The panel header says so ("No finished good running").

**This replaces the tray projection.** `Workorder.Assembly_GetComponentProjection` (on hand vs.
the trays left in the current container) is retired -- Jacques, 2026-09-17.

### 3.3 Which parts are listed

- **Running finished good(s):** every non-FG part in their rolled-up BOM, **shown even at 0**. A
  part that has run out is the one that most needs its button.
- **Everything on hand:** plus every other non-FG part with an open LOT at the line.
- **Idle line:** only on-hand parts.

### 3.4 Where "the line" is

The terminal's session cell (`session.custom.cell.locationId`) resolves up to its **WorkCenter**
ancestor, which is the same resolution `Location.Terminal_ListByLineOf` uses. The inventory pool
is the open LOTs at that WorkCenter and every descendant, consistent with the line-resident flow.
A check-in LOT is created at the same location the Inventory popup's `receiveLoose` uses today.

## 4. Data

### 4.1 Migration `0091_line_inventory_sidebar`

- `ALTER TABLE Parts.Item ADD BoxQuantity INT NULL, LowInventoryHorizon INT NULL`, with checks:
  - both columns: `> 0` when set;
  - `BoxQuantity` only on PassThrough items;
  - `LowInventoryHorizon` only on FinishedGood items.
  - The `> 0` rule is a table CHECK. The item-type rules are enforced in `Item_Create` /
    `Item_Update` (a CHECK would have to hard-code ItemType Ids).
- `DROP PROCEDURE Workorder.Assembly_GetComponentProjection` (and delete its repeatable file).
- Extended properties on the new columns, so the SchemaGen ERD documents them.

### 4.2 Procs

| Proc | Change |
|---|---|
| **`Lots.Lot_GetLineInventorySummary`** (new, read) | `@LocationId BIGINT, @FinishedGoodItemId BIGINT = NULL`. One row per part: `ItemId, Description, Available, Threshold, IsLow, BoxQuantity, AddLotMode`, plus `RunningFinishedGoods` (the resolved FG description(s), repeated on every row, for the header -- one result set). Sorted `IsLow DESC, Description`. Empty set when the location has no WorkCenter ancestor. No OUTPUT params (FDS-11-011). |
| `Parts.Item_Create` / `Parts.Item_Update` | Accept and validate `@BoxQuantity`, `@LowInventoryHorizon`; ConfigLog JSON gains both. `Item_Update` is a **full replace** (`SET col = @param`, so NULL clears), so every caller -- the `parts/Item_Update` NQ and the Item Master Identity save -- **must pass both values through**, or a save from the editor would wipe them. |
| `Parts.Item_Get` (+ list reads the editor uses) | Return both columns. |
| `Lots.Lot_GetLineInventoryByPart` | Exclude FinishedGood items and return `ItemDescription`, so the Inventory popup can drop finished goods and group by description. |
| `Lots.Lot_Create` | **Unchanged.** The button calls it with origin `Received`. Its existing gates still apply: item eligibility at the location, and the `ItemLocation.MaxQuantity` / `Item.MaxParts` caps. A 5,000 box refused by a cap surfaces the proc's message in the toast, and the fix is config, not code. |

### 4.3 Named queries and scripts (Core)

- **New NQ:** `lots/Lot_GetLineInventorySummary` (type Query).
- **Changed NQs:** `parts/Item_Create` and `parts/Item_Update` gain the two params.
- **`BlueRidge.Lots.Lot`:**
  - New `getLineInventorySummary(locationId, finishedGoodItemId=None)`, which always returns a
    list (`[]` on empty).
  - New `checkInBox(itemId, locationId, pieceCount, appUserId, terminalLocationId)`, a thin
    wrapper over `create()` with origin `Received`. The `pieceCount` comes from the row
    (Box Quantity) or from the numpad.
- **`BlueRidge.Workorder.Assembly`:**
  - Remove `getComponentProjection` and `warnLowInventory` (see § 7).

## 5. Screens

### 5.1 New views (file-authored, MPP project)

- **`Components/PlantFloor/LineInventory`** -- the panel.
  - **Params:** `locationId`, `finishedGoodItemId` (optional).
  - **Header:** "Line Inventory" plus a subline ("Low below 50 x <FG>" / "No finished good
    running").
  - **Body:** a flex repeater of rows with no scrolling (`overflow: hidden`).
  - **Footer:** a small *Inventory detail...* button that opens the existing `InventoryManager`
    popup.
  - **Refresh:** on `inventoryChanged` (page-scoped, already broadcast), and on a slow poll
    (30 s) so a check-in at one terminal shows on the others.
  - **Defaults:** every bound custom prop is pre-declared with a shaped default.
- **`Components/PlantFloor/LineInventoryRow`** -- one row: description, available, button
  slot.
  - **Button:** `+<BoxQuantity>` or `+ LOT`, hidden when `AddLotMode = None`.
  - **One-tap:** disables for ~2 s after a press (double-tap guard), calls `checkInBox`, toasts
    "Box checked in -- LOT <name> -- <desc> -- <n> pcs" or the proc's message, then sends
    `inventoryChanged`.
  - **`AskQty`:** embeds the existing `Components/PlantFloor/Numpad` in a small *Add LOT* popup
    (Cancel / Add N pcs).
- **Stylesheet (Core):** `psc-pf-inv-row` and `psc-pf-inv-row-low`, with new tokens
  `--pf-inv-low-bg: rgba(255,145,48,0.16)` and `--pf-inv-low-border: #FF9130`. The plant floor
  is dark-themed, so "light orange" is a pale orange tint, as in the mockup.

### 5.2 Changes to existing views (Designer, per the view-edit boundary)

| View | Change |
|---|---|
| `Views/ShopFloor/MachiningIn` | Root content becomes a row: existing column + `LineInventory` on the right. |
| `Views/ShopFloor/MachiningOutSplit` | Add `LineInventory` to the right of the existing `ContentRow`. |
| `Views/ShopFloor/AssemblyIn` | Same as Machining IN. |
| `Views/ShopFloor/AssemblySerialized` | Remove `ComponentsPanel` (the single label) and `queueByPartText`; dock `LineInventory` right; pass the selected / open-container FG. |
| `Views/ShopFloor/AssemblyNonSerialized` | Replace `InventorySidebar`'s contents (`SidebarList` label + `ProjectionRepeater`) with `LineInventory`; remove `componentProjection` / `queueByPartVertical`; pass the FG. |
| `Components/PlantFloor/InventoryManager` (popup) | Group by part description with LOTs underneath; finished goods excluded (via the proc); low groups use the same orange treatment. |
| `Components/PlantFloor/ComponentProjectionRow` | Deleted (no remaining users). |
| Item Master -> Identity (`MPP_Config`) | *Box Quantity* field (enabled for PassThrough) and *Low-Inventory Horizon* field (enabled for FinishedGood), in the shaped `editDraft`. |

Whoever builds this should check that the width fits each screen's existing content at
terminal resolution. MachiningIn and AssemblyIn are currently full-width columns.

## 6. Testing

- **SQL** -- new `sql/tests/0028_PlantFloor_Assembly/1xx_Lot_GetLineInventorySummary.sql`
  (INSERT-EXEC pattern). Cases:
  - multi-level rollup (casting under an SA under an FG);
  - two running FGs sharing a part (larger threshold wins);
  - selected-FG hint with no open container;
  - idle line (no low flags, only on-hand parts);
  - zero-on-hand BOM part listed;
  - FG items excluded;
  - `AddLotMode` for PassThrough with and without a box size, and for Component;
  - FG with NULL horizon (no flag);
  - location with no WorkCenter ancestor (empty set);
  - sort order.
- **SQL** -- `Item_Create` / `Item_Update`: box size on a non-PassThrough and horizon on a
  non-FG are rejected; `<= 0` rejected; audit JSON carries both.
- **SQL** -- `Lot_GetLineInventoryByPart` excludes FG.
- **Manual (Dev gateway):**
  - each of the five screens shows the panel;
  - 10+ rows without scrolling;
  - a one-tap check-in creates one LOT and refreshes a second terminal on the same line;
  - a double tap creates one LOT;
  - the numpad path works;
  - a cap rejection shows the proc message;
  - the Inventory popup has no FG rows.

## 7. Existing low-inventory toast -- retired

`Workorder.Assembly.warnLowInventory` broadcasts a `lowInventoryWarning` toast to every terminal
on the line after each tray close. It reads the retired tray projection. Under the 50-FG horizon
a part stays low until a box is checked in, so it would toast on every tray.

**Decision (Jacques, 2026-09-17): retire it.** The orange rows already show on every terminal on
the line, which makes the toast redundant.

- Delete `warnLowInventory` and its two call sites in `BlueRidge/Workorder/Assembly/code.py`
  (the operator ByCount tray-close path and `plcCompleteTray`).
- Remove the `lowInventoryWarning` message handler from `Views/ShopFloor/AppHeaderLarge`
  (Designer).
- `Location.Terminal_ListByLineOf` / `Terminal.listByLineOf` stay; they are general-purpose.

## 8. Out of scope

- AIM failure logging, and the shipping-label reprint with the role-gated elevation -- designed
  in the same session and queued behind this (separate specs).
- Removing the Shipping Dock screen -- benched (it is the only UI for Ship Container and Void
  Label).
- Vendor lot capture on check-in; a per-line box size; showing the shortfall number.
