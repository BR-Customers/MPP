# M&A Line Inventory Sidebar -- design

**Date:** 2026-09-17 (revision 2, same day)
**Status:** Built 2026-09-18 on Dev (panel docked on the six M&A pages); live floor check and MPP data entry (Max per consumption part, Box Quantity per bought part) owed; not deployed to prod
**Requested by:** MPP (2026-09-16)
**Mockups:**
- `mockup/line_inventory_sidebar_mock.html` -- row look and density (approved)
- `mockup/line_inventory_options_mock.html` -- the layout options that led to revision 2
- `mockup/line_inventory_rev2_mock.html` -- revision 2
**Screens:** Machining IN, Machining OUT, Assembly IN, Assembly OUT (serialized + non-serialized)

## Revision history

| Rev | Date | Change |
|---|---|---|
| 1 | 2026-09-17 | Low = on hand below (rolled-up BOM qty per finished good x the running FG's `LowInventoryHorizon`). Every BOM part listed. Built as far as Task 8 (see the plan). |
| 2 | 2026-09-17 | **The line's consumption eligibility drives the panel, and the line's `MaxQuantity` drives the colour.** Revision 1 broke at real scale: the RPY and 5BA cam-holder sets roll up to 40-42 parts, and machined sub-assemblies sat orange all day with no button to clear them. Revision 2 changes four things: it lists the parts the line consumes (`Parts.ItemLocation.IsConsumptionPoint`); it colours by % of Max (orange <= 30%, red <= 10%); each terminal type defaults to the parts its operator acts on, with a line-wide toggle; and a Tolerances popup sets Max from the terminal. `Item.LowInventoryHorizon` and the BOM rollup are retired. Box quantity, one-tap and numpad check-in, the held-stock exclusion and the Receiving Dock / popup fixes are kept. |
| 2 (final review) | 2026-09-18 | **Correction pass, no scope change.** 3.5 corrected: a check-in refusal on an orange row is usually the box rule (Max leaves less headroom than one box needs), not held stock -- the box rule (`Max >= Box / 0.7` orange, `Box / 0.9` red) is now spelled out here rather than only implied. 4.2 gains the `ScopeCode` column (`Lot_GetLineInventorySummary`) and the `RowLocationCode` / `LineLocationCode` columns (`ItemLocation_ListConsumptionForLine` v1.1, added so the Tolerances popup can flag a Max shared with an ancestor Area). |

---

## 1. Problem

Operators on the Machining & Assembly lines cannot see or manage line-side stock easily, and that
gap is costing accurate accounting of their work.

- **Machining IN shows no inventory at all.** It is only reachable through the Inventory popup.
- **Assembly OUT (serialized) shows a single text label** -- `"PN: N pcs | PN: N pcs"` -- which is
  poor Ignition practice and hard to read.
- **Assembly OUT (non-serialized)** has a sidebar, but it lists part *numbers* and flags a part low
  only against the trays left in the *current container*.
- **The Inventory popup lists every open LOT**, finished goods included -- mostly noise on an
  assembly line.
- **Bought parts have no quick way in.** Dowel pins arrive in 5,000-piece boxes, and checking one in
  means the full receive flow.

## 2. What we are building

One shared component, **Line Inventory**: a tall, 320px-wide panel docked on the right of all five
M&A screens. It has one compact row per part.

| Row element | Rule |
|---|---|
| **Description** | `Parts.Item.Description`, never the part number (the part number is the fallback only when Description is empty). Wraps to two lines, then clips. |
| **Available** | Sum of `Lot.InventoryAvailable` over the line's LOTs of that part whose status does not block production. It excludes `Closed` and `Open` LOTs and any status with `LotStatusCode.BlocksProduction = 1` (Hold, Scrap). **A held LOT is not available** (Jacques, 2026-09-17). |
| **Colour** | From the part's **Max** at this line (section 3.2): orange at <= 30%, red at <= 10%, none when no Max is set. It colours the whole row with a matching border. No badge and no shortfall number. |
| **Button** | Only on **PassThrough** parts, the bought parts (section 3.4). |

**Density:** rows are 40px with 4px gaps and ~28px buttons, so **12 rows fit with no scrolling**.
Jacques's bar is "8-10 rows on a screen, no scrolling"; that is a hard requirement.

**Overflow:** past the rows that fit, a one-line footer says what is hidden and whether any of it is
coloured, e.g. `+8 more below - all above 30%` or `+3 more below - 2 low`. The list is sorted most
urgent first, so the hidden rows are always the healthiest.

**Finished goods are never listed.**

## 3. Rules

All of these are decided in SQL (`Lots.Lot_GetLineInventorySummary`), per the
no-business-logic-in-Python rule. The views render what they are told.

### 3.1 Which parts are listed

1. **Consumption parts.** Every part with an active `Parts.ItemLocation` row where
   `IsConsumptionPoint = 1`, at the terminal's line or any ancestor of it. This is the same hierarchy
   cascade eligibility already uses. These are listed **even at 0 on hand**, because a part that has
   run out is the one that most needs attention.
2. **Anything else on hand.** Every other non-FG part with available stock at the line.
3. **Terminal scope.** Each terminal type defaults to the parts its operator acts on:

   | Terminal role | Default scope |
   |---|---|
   | Machining IN, Machining OUT | `Component` (the castings) |
   | Assembly IN, Assembly OUT | `PassThrough` (the bought parts) |

   A **Show line-wide parts** toggle in the panel header widens the list to every part from rules 1
   and 2. The toggle is per panel (per session and view) and resets when the screen reloads.

Why this beats revision 1's BOM rollup:
- Machined sub-assemblies are made on the line, not brought to it, so they are not consumption rows
  and never sit orange.
- The list no longer depends on knowing which finished good is running, so it works when the line
  is idle.
- The data already exists: on Dev there are 172 consumption rows, all set at the line tier.

### 3.2 Colour

For each listed part, **Max** = the `MaxQuantity` of the **nearest** consumption row walking up
from the terminal's line (`Depth ASC`), exactly as `Lots.Lot_Create`'s consumption-point cap
resolves it.

| Level | Rule | Row |
|---|---|---|
| `Critical` | `Available <= 10% of Max` | red tint, bright red border |
| `Low` | `Available <= 30% of Max` | orange tint, bright orange border |
| `Ok` | above 30% | plain |
| `None` | no Max configured | plain |

**A part with no Max never changes colour**, so the Tolerances popup is also how a part gets its
warning. `MinQuantity` and `DefaultQuantity` are not used by the panel (Jacques, 2026-09-17).

### 3.3 Order

Most urgent first, by `Available / Max` ascending, so the part nearest empty is on top. Parts with
no Max come after every part that has one, then all are ordered by description, then `ItemId`.

### 3.4 The check-in button (unchanged from revision 1)

| Item type | Button | What one press does |
|---|---|---|
| PassThrough, **Box Quantity set** | `+5,000` (the part's `Parts.Item.BoxQuantity`) | One tap creates one `Received` LOT of that many pieces, attributed to the signed-in operator. |
| PassThrough, **no Box Quantity** | `+ LOT` | Opens the numpad popup for a count, then creates one `Received` LOT. |
| anything else | none | Made parts arrive on their own route. |

- **Box quantity lives on the part**, one size everywhere (Jacques, 2026-09-17).
- **One LOT per box.** No vendor lot is captured.
- **Double-tap guard.** Both the row button and the numpad's Add button disable for 2 s after a
  press.

### 3.5 Max is also the lineside cap -- read this before setting it

`Lots.Lot_Create` already **refuses** a Received LOT that would push the pieces at a consumption
point past its `MaxQuantity`. So setting Max does two things: it sets the colour scale, and it caps
check-ins. For example, a Max of 500 means a 5,000-piece box can never be checked in there.

The cap and the panel count slightly different pools. The difference is deliberate, and the popup
explains it:

| | Panel (colour) | `Lot_Create` cap |
|---|---|---|
| Quantity | `InventoryAvailable` | `PieceCount` |
| Where | the line and everything under it | the exact location the LOT is created at (the line, since terminals zone up to it) |
| Held LOTs | excluded (not available) | **included** (they still take up space) |

**The box rule.** A one-tap check-in only fits while `Available <= Max - Box`, so Max has to leave
room for a whole box, not just for some stock. To ever refill an orange row (<= 30% of Max), Max must
be at least about `Box / 0.7` -- for example, 5,000-piece boxes need a Max of about 7,200 or more; for
a red row (<= 10% of Max), at least about `Box / 0.9`. **This, not held stock, is the usual reason a
check-in gets refused on a row that still shows orange** -- Max was set without headroom for one whole
box. Held stock filling the space (the differing pools above) is the rarer case. Refused check-ins
should not be blamed on held stock by default; check the box size against Max first. The refusal
message already reads `N present, cap M`. `Lot_Create` is **not** changed by this work.

### 3.6 The Tolerances popup

- Opened from a **Tolerances** button in the panel header.
- Lists the consumption parts of the terminal's line (rule 3.1.1, line-wide, ignoring the terminal
  scope). Each row shows the part description, current available, and an editable **Max**.
- **Anyone signed in may save** (Jacques, 2026-09-17). Presence by PIN is enough; no AD elevation.
- Saving writes through a new proc, `Parts.ItemLocation_SetMaxQuantity`, which touches **only**
  `MaxQuantity` and writes a ConfigLog row per change.
  - It does not reuse `Parts.ItemLocation_SetConsumptionMetadata`: that proc replaces every column
    it is given, so it would wipe Min and Default.
  - It edits the consumption row the colour was resolved from, which may be at an ancestor of the
    line (section 3.2).
  - It rejects a negative Max, and a Max below a configured `MinQuantity` (the same rule
    `ItemLocation_Add` enforces). A blank field clears Max, and the part then stops colouring.
- The popup carries a one-line warning under its title: *"Max is also the most this line can hold
  -- a check-in that would go over it is refused."*

## 4. Data

### 4.1 Migrations

- **`0091_line_inventory_sidebar`** (built, on Dev): `Parts.Item.BoxQuantity` and
  `Parts.Item.LowInventoryHorizon`.
- **New migration, `0092` or the next free number:**
  - drop `Parts.Item.LowInventoryHorizon` and its CHECK;
  - drop `Workorder.Assembly_GetComponentProjection` (and delete its repeatable file in the same
    commit, so `Update-Prod` doesn't recreate it).

  0091 is already recorded on Dev, so it cannot be edited; the drop has to be forward.
  `LowInventoryHorizon` has never reached prod.

### 4.2 Procs

| Proc | Change |
|---|---|
| **`Lots.Lot_GetLineInventorySummary`** | **Rewritten** as v2.0. Signature `@LocationId BIGINT, @TerminalRole NVARCHAR(30) = NULL, @LineWide BIT = 0`. `@TerminalRole` is the operation-type role code (`MachiningIn` / `MachiningOut` / `AssemblyIn` / `AssemblyOut`), mapped to an item type in SQL per section 3.1. NULL or `@LineWide = 1` means no type filter. Returns one row per part: `ItemId, Description, Available, MaxQuantity, Level` (`Critical`/`Low`/`Ok`/`None`), `BoxQuantity, AddLotMode` (`OneTap`/`AskQty`/`None`), `ItemLocationId` (the consumption row Max came from, NULL if none), `ScopeCode` (`Component`/`PassThrough`/`All` -- what the header's scope sentence is keyed from). The overflow footer is computed by the view from row count, so the proc keeps one plain result set. Sorted per section 3.3. The FG-hint parameter and all BOM/running-FG logic are removed. |
| **`Parts.ItemLocation_SetMaxQuantity`** (new) | `@ItemLocationId BIGINT, @MaxQuantity INT = NULL, @AppUserId BIGINT`. Status-row mutation; ConfigLog row using the Description convention (`<part> - Eligibility - Updated MaxQuantity a->b @ <location>`, with the mid-dot and arrow per the audit convention); validations per section 3.6. |
| **`Parts.ItemLocation_ListConsumptionForLine`** (new, read) | `@LocationId BIGINT`. The popup's list: `ItemLocationId, ItemId, Description, Available, MaxQuantity, MinQuantity, RowLocationCode` (where the winning consumption row actually lives), `LineLocationCode` (v1.1 -- the resolved line's own Code, so the popup can tell a row shared with an ancestor Area from one scoped to this line), over the consumption rows resolved per section 3.2 (nearest wins per part), with Available computed as in section 2. |
| `Parts.Item_Update` | Remove `@LowInventoryHorizon` and its validation, diff and audit. `@BoxQuantity` stays as built (NULL-preserving, 0 clears, type check only on set/change). |
| `Parts.Item_Get` | Drop the `LowInventoryHorizon` column (it was appended last, so only the fixed-shape test captures need narrowing). |
| `Lots.Lot_GetLineInventoryByPart` | Unchanged (v1.3: `@ExcludeFinishedGoods`, description ordering). |
| `Lots.Lot_Create` | **Unchanged.** Its eligibility gate and consumption-point cap apply to check-ins (section 3.5). |

### 4.3 Named queries and scripts (Core)

- **NQ changes:**
  - `lots/Lot_GetLineInventorySummary` takes the new parameters.
  - New `parts/ItemLocation_ListConsumptionForLine`.
  - New `parts/ItemLocation_SetMaxQuantity` (type Query, status row).
  - `parts/Item_Update` drops `lowInventoryHorizon`.
- **`BlueRidge.Lots.Lot`:**
  - `getLineInventoryInstances(locationId, terminalRole=None, lineWide=False, _refreshToken=None)` --
    rows gain `level`, and `isLow` is replaced by `level`.
  - `getLineInventoryHeader(...)` -- same arguments. It returns the scope sentence ("Castings at this
    line" / "Bought parts at this line" / "All parts this line uses").
  - `getLineInventoryFooter(...)` -- the overflow sentence, or `""`.
  - `checkInBox` / `checkInAndNotify` -- unchanged.
- **`BlueRidge.Parts.ItemLocation`:** `listConsumptionForLine(locationId)` and
  `setMaxQuantity(itemLocationId, maxQuantity)`. The Max wrapper maps a blank to NULL (clear) and
  sends `inventoryChanged` so the panel recolours.
- **`BlueRidge.Parts.Item.update`:** drop the `lowInventoryHorizon` key.

## 5. Screens

### 5.1 New and changed views (file-authored; all created today)

- **`Components/PlantFloor/LineInventory`**
  - New params `terminalRole` (string) and `custom.lineWide` (bool, default false).
  - Header: title, scope sentence, a **Line-wide** toggle button and a **Tolerances** button.
  - Footer: the overflow sentence plus the existing *Inventory detail...* button.
  - The `finishedGoodItemId` param is removed.
- **`Components/PlantFloor/LineInventoryRow`** -- `isLow` becomes `level`, which picks the class:
  `pf-inv-row`, `pf-inv-row pf-inv-row-low`, or `pf-inv-row pf-inv-row-crit`.
- **`Components/PlantFloor/LineTolerances`** (new popup)
  - A list of consumption parts, each with description, available and a numeric Max field.
  - One Save per row (row-scoped, so there is no bundled dirty-state machine), plus the section 3.6
    warning line.
  - The numeric field uses the plant-floor numpad popup pattern, because terminals have no keyboard.
- **Stylesheet (Core):** add `--pf-inv-crit-bg: rgba(239,68,68,0.18)`, `--pf-inv-crit-border:
  #F05252` and `.psc-pf-inv-row-crit`, mirroring the low pair.

### 5.2 Existing views (Designer)

| View | Change |
|---|---|
| `Views/ShopFloor/MachiningIn` | Dock `LineInventory` right, `terminalRole = "MachiningIn"`. |
| `Views/ShopFloor/MachiningOutSplit` | Dock right, `terminalRole = "MachiningOut"`. |
| `Views/ShopFloor/AssemblyIn` | Dock right, `terminalRole = "AssemblyIn"`. |
| `Views/ShopFloor/AssemblySerialized` | Remove `ComponentsPanel` + `queueByPartText`; dock right, `terminalRole = "AssemblyOut"`. |
| `Views/ShopFloor/AssemblyNonSerialized` | Replace `InventorySidebar`'s contents with the panel, `terminalRole = "AssemblyOut"`; remove `componentProjection` / `queueByPartVertical`. |
| `Components/PlantFloor/InventoryManager` | Switch the `OnHandRepeater` binding from `getLineInventoryCards` to `getInventoryPopupCards` (finished goods excluded, descriptions). `getLineInventoryCards` keeps its original behaviour for the Receiving Dock. |
| `Views/ShopFloor/AppHeaderLarge` | Remove the `lowInventoryWarning` handler (the toast is retired, section 7). |
| Item Master -> Identity (`MPP_Config`) | Add the **Box Quantity** field (enabled for PassThrough). No horizon field. |

All five screens pass `session.custom.cell.locationId` as `locationId`.

## 6. Testing

- **SQL, `Lot_GetLineInventorySummary` v2.0:**
  - consumption parts listed at 0;
  - an on-hand non-consumption part listed;
  - FG never listed;
  - held and closed LOTs excluded from Available;
  - each terminal role's scope and `@LineWide`;
  - Max resolved from the nearest ancestor row when two tiers have one;
  - the 10% / 30% boundaries, **at** and just above each;
  - a part with no Max gets `None` and sorts after parts that have one;
  - the sort order;
  - `AddLotMode`;
  - an area-level location returns an empty set.
- **SQL, `ItemLocation_SetMaxQuantity`:**
  - sets Max, and changes only Max (Min and Default untouched);
  - a blank clears it;
  - negative rejected;
  - below Min rejected;
  - audit row written;
  - an unknown or deprecated row rejected.
- **SQL, `ItemLocation_ListConsumptionForLine`:** nearest-row resolution, and Available as in
  section 2.
- **SQL, cleanup:** `Item_Update` and `Item_Get` tests narrowed by the dropped column; the projection
  test file deleted with its proc.
- **Manual (Dev gateway):**
  - each screen shows its default scope and the toggle widens it;
  - 12 rows fit and the footer is correct;
  - setting a Max in the popup recolours the panel on a second terminal within 30 s;
  - a one-tap check-in over Max is refused with the `N present, cap M` message.
- **Dev needs migration `0089`** (the PassThrough retype) before any button renders, because Dev has
  no PassThrough parts today. Applying it is Jacques's call.

## 7. Existing low-inventory toast -- retired

`Workorder.Assembly.warnLowInventory` toasted every terminal on the line after each tray close,
reading the tray projection. **Retired (Jacques, 2026-09-17):** the coloured rows show on every
terminal. Delete `warnLowInventory` and its two call sites, remove the `AppHeaderLarge` handler, and
drop the projection proc (section 4.1).

## 8. Out of scope

- AIM failure logging, the shipping-label reprint and the Shipping Dock removal. These are separate
  work; see `notes/2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md`.
- Vendor lot capture on check-in, per-line box size, a shortfall number, an undo for a mis-pressed
  check-in, and grouped header rows in the Inventory popup (a later Designer pass).
- Changing `Lots.Lot_Create`'s consumption-point cap to match the panel's pool (section 3.5).
