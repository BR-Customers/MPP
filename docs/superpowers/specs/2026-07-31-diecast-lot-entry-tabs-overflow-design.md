# Die Cast LOT Entry — Tab Restructure, Overflow Gate, Cleanup

**Date:** 2026-07-31
**Author:** Blue Ridge Automation (Jacques + Claude)
**Status:** Design — approved in brainstorming, pending spec review
**Surface:** `BlueRidge/Views/ShopFloor/DieCastBody` (shared body; `DieCastShared` /
`DieCastDedicated` are thin wrappers that embed it) and its `DieCastEntry/*` sub-views.

---

## 1. Context

The Die Cast LOT Entry screen is the plant-floor terminal where operators open
accumulator baskets (one per tool+cavity), record per-shift die-wide gross shots
(auto-split into per-cavity good/scrap), release full baskets to Trim, and void
empty ones. Today the whole screen is a single 4-panel wrapped flex row:

| Panel | Width | Role |
|---|---|---|
| Open Basket | 380px | Scan LTT + pick item/cavity → open a basket |
| Record Shift Output | 620px grow | Shift/gross entry, per-cavity breakdown, shot loss, submit |
| Currently Open | 360px | Open-basket list with Release / Void |
| Right rail | 320px | Shots / Good / Scrap this shift + Recent activity |

Four problems, addressed here:

1. **Mojibake** — two expression string literals contain triple-mis-encoded
   middots (`Ãƒâ€šÃ‚Â·` and `Ã‚Â·`) that render as garbage in the Subtitle and the
   cavity-row "headroom" label.
2. **Inconsistent sizing** — `ia.input.dropdown` has no min-height while
   `.psc-pf-field-input` text fields do (`--pf-touch-min`), so inputs in the same
   row render at different heights; narrow scrap dropdowns wrap their placeholder
   across three lines, making cavity rows ragged.
3. **Cramped single-screen layout** — four panels competing for width.
4. **Silent basket overflow (bug)** — `MaxHeadroom = MaxPieceCount − PieceCount`
   is computed and surfaced, but neither the UI nor `DieCastShiftOutput_Record`
   enforces it. Submitting good pieces beyond a basket's remaining capacity only
   sets a soft `overHeadroom` warning and writes anyway, so a basket silently
   exceeds its physical `MaxLotSize`.

## 2. Goals / Non-goals

**Goals**
- Reorganize the three working panels into a tab container (Open Basket /
  Record Shift Output / Lot Release), with the header, active-cell picker, and
  KPI rail persistent around it.
- Add a real overflow gate: on submit, if any cavity would exceed basket
  capacity, present a resolution popup offering (a) fill-to-capacity → release →
  scan a new LTT that opens the next basket for the remainder, or (b) overfill
  and continue.
- Fix the mojibake.
- Make all inputs in the shift-output rows uniform height; stop the dropdown
  placeholder wrapping.

**Non-goals**
- No change to genealogy, contribution-ledger, or release/void semantics.
- No recursive multi-basket splitting: the overflow remainder goes into **one**
  new basket even if that itself exceeds capacity (accepted as overfill — the
  operator has already opted in). Documented limitation, not a bug.
- No change to the wrappers' presence/cell-guard `onStartup` logic.

## 3. Part A — Tab restructure

### Layout

```
root (flex column, canvas, gap 16, padding 24)
├─ HeaderBand                [persistent]  Title/Subtitle · Operator · Refresh · Close
├─ ContextBar                [persistent]  Active Cell picker (display bound to cellPickerEnabled)
└─ MainRow (flex row, grow 1, gap 16)
   ├─ TabContainer (ia.container.tab, grow 1)
   │    child[0] "Open Basket"          ← existing OpenPanel container (moved verbatim)
   │    child[1] "Record Shift Output"  ← existing ShiftOutputPanel container (moved verbatim)
   │    child[2] "Lot Release"          ← existing CurrentlyOpenPanel container (moved verbatim)
   └─ RightRail (flex column, basis 320px)   [persistent]  existing CumulativeCard + PeerCard
```

### Mechanics

- Reuse the `ia.container.tab` schema already proven in `MachiningStation`:
  `menuType:"modern"`; `tabs:[{text,runWhileHidden:true,disabled:false} ×3]` in
  the same order as the children; `menuStyle.classes:"tab-strip"`,
  `contentStyle.classes:"tab-content-fill"`,
  `tabStyle.active.classes:"tab-item tab-item-active"`,
  `tabStyle.inactive.classes:"tab-item"`, `tabStyle.disabled.classes:"tab-item"`.
  All four classes already exist in the Core stylesheet — **no new tab CSS.**
- Each tab child is the **existing panel container moved unchanged** under the
  tab container. All bindings, `customMethods`, and `messageHandlers` are
  view-level (`view.custom.*`, `self.<method>()`), so relocating the containers
  does not touch any of them. `self.view.rootContainer.<method>()` call sites in
  the sub-components are unaffected (they address the view root, not the moved
  container).
- New `view.custom.activeTab` (int, default 0) bound bidirectionally to
  `TabContainer.props.currentTabIndex`, so scripts can switch tabs (e.g. after a
  successful release the operator can be returned to Open Basket; after an
  overflow-fill the new basket lands on Lot Release). Initial scope: declare it
  and wire `currentTabIndex`; auto-switch behaviours are opt-in per action and
  listed in the plan, not required for MVP.
- `defaultSize.width` stays 1280. The `Body` wrapped-flex container is replaced
  by `MainRow`; `wrap:"wrap"` is dropped (tabs remove the need to wrap).

## 4. Part B — Overflow gate (Option A: reuse existing procs)

### 4.1 SQL (one small change)

`Workorder.DieCast_GetShiftOutputBreakdown` (repeatable migration
`R__Workorder_DieCast_GetShiftOutputBreakdown.sql`): add `l.ItemId` to the final
`SELECT` (source column already present on `Lots.Lot l`). Needed so the overflow
resolver can open the next basket with the same item. No other proc changes; no
new proc. `MaxHeadroom` already returned (`MaxPieceCount − PieceCount`, or
`2147483647` when the item has no `MaxLotSize` cap).

`BlueRidge.Workorder.DieCast.mapBreakdownInstances` gains `itemId` in its output
dict for completeness (display sub-view ignores it). `view.custom.breakdown`
holds the **raw** proc rows, so `submitShiftOutput` reads `r.get("ItemId")`
directly regardless.

### 4.2 Submit path (`DieCastBody.submitShiftOutput`)

Extend the existing per-row loop. For each **open** row it already derives the
final good delta `g` (operator entry, else `ProposedGood`). Add:

- `h = r.get("MaxHeadroom")`; if `g > h and h < 2147483647` → this cavity
  overflows. Collect `{lotId, lotName, cavityNumber, toolCavityId, itemId,
  headroom: h, good: g, remainder: g − h, scrapLines}`.

Then:

- **No overflow** → `recordShiftOutput(lines)` exactly as today.
- **≥1 overflow** → stash `view.custom.pendingSubmit = {lines, overflow,
  shiftId, toolId, cellLocationId, terminalLocationId}` and open the
  `DieCastOverflow` popup. **Nothing is written yet.**

### 4.3 Popup — `BlueRidge/Components/Popups/DieCastOverflow` (new view)

Params: `overflow` (list), `replyMessage` ("dieCastOverflowResult"), `popupId`.
One row per overflow cavity:

> **Cavity 1 · 000000001** — basket full at 1000 (900 on it). Submitting 1200 pc:
> **100 fits, 1100 overflow.**
> `[ Scan new LTT for the overflow basket ]`   (mono text-field, per row)

Local `view.custom.ltts` map `{lotId → scannedLtt}` (bidirectional per row).
Buttons:

- **Fill, release & continue** (primary; enabled only when every row has a
  non-blank LTT) → reply `{action:"fill", ltts:{lotId:ltt,…}}` then close.
- **Overfill baskets** (secondary/danger styling) → reply `{action:"overfill"}`
  then close.
- Header X / Cancel → reply `{action:"cancel"}` then close.

Follows the existing `ConfirmAction` reply-message pattern (page-scoped reply,
popup closes itself, parent routes the action). New view (no Designer cache) →
safe to author as files + scan.

### 4.4 Resolver (`DieCastBody`, message handler `dieCastOverflowResult` →
`resolveOverflow(action, ltts)`)

Reconstruct from `view.custom.pendingSubmit`. Then:

- **cancel** → clear `pendingSubmit`, no writes.
- **overfill** → `recordShiftOutput(pendingSubmit.lines)` with the **original**
  (uncapped) quantities = today's lenient behaviour. Refresh on success.
- **fill** → for the two groups:
  1. **Non-overflow cavities** → one `recordShiftOutput(nonOverflowLines)`
     (`lines` minus the overflow lots). **Skip this call entirely when
     `nonOverflowLines` is empty** — an empty batch would hit the proc's
     "nothing to submit" path.
  2. **Each overflow cavity, in order**:
     a. `releaseDieCast({lotId: oldLot, finalPieceDelta: headroom,
        scrapLines: thatCavityScrap, shiftId, appUserId, terminalLocationId})`
        — tops basket 1 to exactly `MaxPieceCount` with its remaining headroom
        good + its scrap, then closes/moves it to Trim. (`releaseDieCast` already
        supports `finalPieceDelta` + `scrapLines`.)
     b. `openDieCast({itemId, currentLocationId: cellLocationId, toolId,
        toolCavityId, lotName: ltts[oldLot], appUserId, terminalLocationId})`
        → capture `NewId = newLot`.
     c. `recordShiftOutput({shiftId, toolId,
        lines:[{lotId: newLot, pieceDelta: remainder, scrapLines: []}]})`
        — remainder into basket 2.
  Each step checks `Status`; on the first failure, `notifyResult` surfaces the
  proc `Message` and the sequence **stops** (leaving a consistent, visible
  partial state the operator can finish by hand). On full success: clear
  `pendingSubmit`, reset `grossShots`/`breakdown`/`breakdownEntries`, bump
  `refreshToken`.

**Atomicity note:** the fill path is **not** a single transaction, but every
sub-op is individually atomic and its result is immediately reflected in the
open-basket list and KPIs — a mid-sequence failure is operator-recoverable
(basket 1 shows released; basket 2 shows its count; remainder can be re-entered).
This is the explicit Option-A trade-off chosen over a new transactional proc.

The inline soft `overHeadroom` warning on `CavityLotRow` stays (informative
preview); the hard gate now lives at submit.

## 5. Part C — Mojibake fix

Replace the two garbled middots with a clean literal `·` (U+00B7), matching
`OpenBasketRow` which already uses a literal `·` and renders correctly. Files
are written UTF-8; do **not** reintroduce the Windows-codepage double-encoding.

- `DieCastBody` `Subtitle` expression: `… · SHARED TERMINAL · …`
- `CavityLotRow` `ReferenceLabel` expression: `… · headroom N`

(Expression string literals cannot use `\u` escapes — embed the literal char, per
`feedback_ignition_expr_no_unicode_escape`.)

## 6. Part D — Uniform sizing

Root cause: `.ia_dropdown` has only padding; `.psc-pf-field-input` sets
`min-height: var(--pf-touch-min)`. Fix in the **Core** stylesheet (canonical;
never the dropped MPP mirror):

- Add `min-height: var(--pf-touch-min)` and `white-space: nowrap` to the
  `.ia_dropdown` rule so every dropdown matches text-field height and stops
  wrapping its placeholder. (Global to plant-floor + config; verify no config
  dropdown depends on the shorter height — low risk, they share the touch
  target already.)
- In `CavityLotRow`, standardize column bases so all cavity rows align: fixed
  `GoodBlock` basis, fixed `ReferenceLabel` min-width, and give the scrap
  dropdowns a sensible min-width so the placeholder never wraps. The wider
  Record-Output tab (full width minus the 320px rail) supplies the room.

## 7. Files touched

| File | Change |
|---|---|
| `…/ShopFloor/DieCastBody/view.json` | Tab restructure; `activeTab` custom prop; `submitShiftOutput` overflow branch; `resolveOverflow` method + `dieCastOverflowResult` handler + `pendingSubmit` state; Subtitle mojibake |
| `…/DieCastEntry/CavityLotRow/view.json` | Reference-label mojibake; column-basis sizing |
| `…/Components/Popups/DieCastOverflow/{view.json,resource.json}` | **New** popup view |
| `Core/…/stylesheet/stylesheet.css` | `.ia_dropdown` min-height + nowrap |
| `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql` | Add `l.ItemId` to SELECT |
| `Core/…/BlueRidge/Workorder/DieCast/code.py` | `itemId` in `mapBreakdownInstances` |

## 8. Testing / verification

- **SQL:** extend `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql`
  (or a sibling) to assert the breakdown now returns `ItemId`. Run the die-cast
  lifecycle test bundle; confirm no regression.
- **Overflow mechanism (dev DB):** with a capped-`MaxLotSize` item, open a
  basket, drive `PieceCount` near cap, submit a gross that overflows one cavity,
  exercise both popup actions:
  - *fill* → basket 1 released at exactly cap, basket 2 opened on the scanned
    LTT with the remainder, KPIs sum correctly, genealogy intact.
  - *overfill* → single basket exceeds cap (today's behaviour), one write.
  - multi-cavity overflow → one new LTT per overflowing cavity.
- **View render:** after `scan.ps1`, open DieCastShared + DieCastDedicated;
  confirm three tabs switch, persistent header/cell/KPI rail, mojibake gone,
  uniform input heights, no dropdown wrap.
- **Regression:** open/clear/release/void, shot loss, compute/preview, operator
  switch, cell picker (shared) all still work post-restructure.

## 9. Risks

- **Ignition file-edit boundary:** DieCastBody + CavityLotRow are existing views
  with a Designer cache. Per project convention, file edits to existing views can
  race Designer's in-memory model. Mitigation: Jacques has granted explicit
  permission for these edits; author carefully (respect the `=`/`<`/
  `>` escape forms and literal `·`), run `scan.ps1`, and reopen the views in
  Designer after scan. The new `DieCastOverflow` popup has no cache → safe.
- **Shared working tree:** the tree already carries other uncommitted work
  (`Location/Location` `_seedAttrValue`, and pre-existing DieCast view/config
  edits). Stage explicit paths only; never `git add -A`/`-u`.
- **Non-atomic overflow fill** — accepted, see §4.4.
- **Global `.ia_dropdown` height** — could nudge config-app dropdowns; verify.

## 10. Rollout

Author files → `scan.ps1` (Core script + stylesheet + MPP views + new popup) →
apply the repeatable SQL migration to dev → run die-cast tests → visual check in
Designer/session. Commit on `jacques/working` with explicit paths.
