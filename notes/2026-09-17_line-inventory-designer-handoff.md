# Line Inventory -- Designer handoff (what is left for Jacques)

**Date:** 2026-09-17
**Spec:** `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` (revision 2)
**Plans:**
- `docs/superpowers/plans/2026-09-17-line-inventory-sidebar.md`: Tasks 1-6 and 8 built.
- `docs/superpowers/plans/2026-09-17-line-inventory-rev2.md`: R1-R5 built.

**Mockup:** `mockup/line_inventory_rev2_mock.html`

Everything an agent can build is built, reviewed and applied to `MPP_MES_Dev`. The remaining steps
are edits to EXISTING views, which go through Designer.

## 1. What is built

- **SQL (applied to Dev, by file):**
  - `0091` adds `Item.BoxQuantity` (and the horizon, since retired).
  - `0094` retires `Item.LowInventoryHorizon`.
  - `Lots.Lot_GetLineInventorySummary` v2.0.
  - `Parts.ItemLocation_SetMaxQuantity`.
  - `Parts.ItemLocation_ListConsumptionForLine`.
  - `Lots.Lot_GetLineInventoryByPart` v1.3 (opt-in `@ExcludeFinishedGoods`).
  - `Parts.Item_Update` v2.7 and `Parts.Item_Get` v2.5.
- **Named queries (Core):**
  - `lots/Lot_GetLineInventorySummary`
  - `lots/Lot_GetLineInventoryByPart`
  - `parts/Item_Update`
  - `parts/ItemLocation_ListConsumptionForLine`
  - `parts/ItemLocation_SetMaxQuantity`
- **Python:**
  - `BlueRidge.Lots.Lot` (summary, instances, header, footer, check-in, popup cards).
  - `BlueRidge.Parts.ItemLocation` (tolerance list, Max save).
  - `BlueRidge.Parts.Item.update` (box quantity).
- **New views (MPP, `Components/PlantFloor/`):**
  - `LineInventory`, `LineInventoryRow` (the panel and its row);
  - `AddLotQty` (numpad count for a part with no box size);
  - `LineTolerances`, `LineToleranceRow`, `LineToleranceEdit` (the Tolerances popup and its numpad
    Max editor).
- **Core stylesheet:** `.psc-pf-inv-*`, with low (orange) and critical (red) levels.

## 2. Designer steps (Task R6)

### 2.1 Dock the panel on the M&A pages (page docks, not embeds)

**Revised 2026-09-18 with Jacques:** instead of embedding `LineInventory` into each screen's
layout, add it as a **right page dock** in Page Configuration. That needs no layout surgery on the
five screens, and page-scoped `inventoryChanged` messages still reach it.

`LineInventory` now resolves its own location: `custom.locationId` is `params.locationId` when one
is passed, else `session.custom.cell.locationId` (commit `d5dfa7d8`). A
dock passes static values only, so it passes **just `terminalRole`**.

Per page, add a right dock:
- **View:** `BlueRidge/Components/PlantFloor/LineInventory`.
- **Display:** `visible`.
- **Content:** `push`.
- **Size:** **320**. The rows are laid out for 320px; 300 squeezes the description.
- **Handle:** `hide`.
- **View Parameters:** `terminalRole` =

| Page | `terminalRole` |
|---|---|
| `/shop-floor/machining-in` | `MachiningIn` |
| `/shop-floor/machining-out` | `MachiningOut` |
| `/shop-floor/machining` (both halves) | `MachiningIn` |
| `/shop-floor/assembly-in` | `AssemblyIn` |
| `/shop-floor/assembly-serialized` | `AssemblyOut` |
| `/shop-floor/assembly-nonserialized` | `AssemblyOut` |

Each page needs its OWN value, so do not configure several pages at once with one parameter.

Then, in Designer, remove what the panel replaces:
- `AssemblySerialized`: `Body/ComponentsPanel` and `custom.queueByPartText`.
- `AssemblyNonSerialized`: the `InventorySidebar` column and `custom.componentProjection` /
  `custom.queueByPartVertical`.

Otherwise both screens show the old inventory next to the new panel. Every screen also keeps its
"Inventory" header button, which opens the same popup as the panel's **Detail...**; decide whether to
keep both.

### 2.2 `Components/PlantFloor/InventoryManager`

Switch `OnHandRepeater`'s instances binding from `BlueRidge.Lots.Lot.getLineInventoryCards` to
**`BlueRidge.Lots.Lot.getInventoryPopupCards`**, keeping the same arguments. That removes finished
goods and shows part descriptions. The Receiving Dock keeps `getLineInventoryCards` on purpose: part
numbers there match the packing slip.

### 2.3 Item Master -> Identity (`MPP_Config`, `Components/Parts/ItemMaster/Identity`)

Add a **Box Quantity** field bidi-bound to `view.custom.state.editDraft.BoxQuantity`, enabled when
`ItemTypeName = "Pass-Through"`.
- Add `"BoxQuantity": ""` to BOTH `state.selected` and `state.editDraft` defaults.
- Add `"BoxQuantity": _s(row.get("BoxQuantity"))` to `load()`.
- In `handleSave()`, add `payload["BoxQuantity"] = draft.get("BoxQuantity")` -- the RAW draft value,
  not `_toNum(draft.get("BoxQuantity"))`. `_toNum("")` returns `None`, and `Item.update` treats `None`
  as "leave alone," so `_toNum` would silently reintroduce the can't-clear bug: an emptied field would
  send nothing and the old BoxQuantity would stick. Sending the raw value lets a blank arrive as `""`,
  which `Item.update` maps to `0`, and the proc treats `0` as clear.

### 2.4 `Views/ShopFloor/AppHeaderLarge`

Remove the `lowInventoryWarning` message handler. The toast is retired, because the coloured rows now
show on every terminal.

## 3. After the Designer steps

- **Task R7:** retire the tray projection. Take the **next free** migration number (never `0092`),
  and delete:
  - `Workorder.Assembly_GetComponentProjection` and its repeatable file;
  - test `0028/094`;
  - NQ `workorder/Assembly_GetComponentProjection`;
  - `Workorder.Assembly.getComponentProjection` and `warnLowInventory` (+ its 2 call sites);
  - `Components/PlantFloor/ComponentProjectionRow`.

  It is blocked until the AssemblyNonSerialized sidebar is removed (2.1), because that sidebar still binds the projection.
- **Live check:**
  - each screen shows its default scope, and **Line-wide** widens it;
  - a Max set in **Tolerances** recolours the panel on a second terminal within 30 s;
  - a one-tap check-in over Max is refused with `N present, cap M`.

## 4. Data MPP has to enter

Nothing colours until this is set:
- **A Max per consumption part per line.** Use **Tolerances** on any terminal (anyone signed in)
  or the Config Tool Eligibility tab. Orange is at or below 30% of Max, red at or below 10%.
- **Box Quantity per bought part.** Use Item Master. Without it, a bought part shows **+ LOT** (the
  numpad) instead of one-tap.

**Max is also the check-in cap.** `Lots.Lot_Create` refuses a Received LOT that would push the pieces
at the line past Max. Set it to the most the line should ever hold, not the reorder point.

**The box rule.** A one-tap check-in only fits while `Available <= Max - Box`, so Max has to leave
room for a whole box, not just for "some" stock. To refill an orange row (<= 30% of Max) at all, Max
must be at least about `Box / 0.7` -- for example, 5,000-piece boxes need a Max of about 7,200 or
more. For a red row (<= 10% of Max) Max must be at least about `Box / 0.9`. Set Max too tight relative
to the box size and every refusal will look like held stock is eating the space, when the real cause
is Max leaving less headroom than one box needs.

## 5. Dev caveats

- **Dev has no PassThrough parts until migration `0089` is applied there.** Dev has 0085-0087, 0090, 0091, 0093
  and 0094, but not 0088 or 0089. Until then the bought fasteners are still typed Component, so they
  show on the **Machining** screens with no button, and Assembly OUT's list is empty. Seen on
  `MA2-6FBCHOP` on 2026-09-17: six parts under MachiningIn, none under AssemblyOut. Applying
  `0088`/`0089` to Dev is your call. They are other sessions' migrations, so I did not run
  `Update-Prod` against Dev.
- Because Dev already holds `0093`/`0094`, `0088` and `0089` now sit **below** Dev's high-water mark.
  `Update-Prod.ps1` against Dev will flag them as out of order and needs `-AllowOutOfOrder`. Its
  `-Preview` shows exactly what it would apply.
- On that line only `6FB Oil Pan Raw` has a Max (500). It shows **red** at 0 available; the rest have
  no Max and no colour.

## 6. Release note

None of this has a prod-release handoff yet. `Deploy-ProdRelease.ps1` applies every pending migration
and every changed repeatable in the checkout, so any release built from HEAD carries `0091`, `0094`
and every proc above. See `notes/2026-09-17_prod-release-handoff-assembly-out-reprint.md` section 0.1,
which flags the same thing from the reprint side.
