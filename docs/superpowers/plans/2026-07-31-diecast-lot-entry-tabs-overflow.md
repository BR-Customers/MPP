# Die Cast LOT Entry — Tabs, Overflow Gate & Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the Die Cast LOT Entry screen into three tabs (Open Basket / Record Shift Output / Lot Release) with a persistent KPI rail, add a hard basket-overflow gate with a resolution popup, fix mojibake, and make input sizing uniform.

**Architecture:** File-authored edits to Ignition Perspective `view.json` + one repeatable SQL proc, then `scan.ps1` to sync the gateway. The overflow flow (Option A) composes three existing procs (`releaseDieCast` with `finalPieceDelta` → `openDieCast` → `recordShiftOutput`) orchestrated from a view `customMethod`; the only SQL change is adding `ItemId` to the breakdown read proc so the resolver can open the next basket with the right item.

**Tech Stack:** Ignition 8.3 Perspective (`view.json`), Jython 2.7 view `customMethods`, SQL Server 2022 (repeatable migration + `test.*` sqlcmd harness).

**Design spec:** `docs/superpowers/specs/2026-07-31-diecast-lot-entry-tabs-overflow-design.md`

## Global Constraints

- **Branch:** commit on `jacques/working`. Stage **explicit paths only** — never `git add -A`/`-u` (the tree carries concurrent work). Omit the `Co-Authored-By: Claude` trailer.
- **After any Ignition resource write, run `.\scan.ps1`** (from repo root) so the gateway re-scans. New views also need a `resource.json` beside `view.json` (`scope:"G"`, `files:["view.json"]`) or they render "View Not Found".
- **File-edit boundary:** `DieCastBody` and `CavityLotRow` are **existing** views with a Designer cache — author carefully; after scanning, the human reopens them in Designer. New views (`DieCastOverflow*`) have no cache and are file-safe. Ask the human to close those two views in Designer before editing if open.
- **Sizing is a view-config fix, NOT a stylesheet change.** Touch-height for inputs is already provided by the existing `.psc-pf-field-input` / `.psc-pf-field-select` classes (`min-height: var(--pf-touch-min)`, 44px). The DieCast dropdowns render class-less, which is why they mismatch the text fields. Fix = apply `pf-field-select` to those dropdowns in the views. Do **not** add a global `.ia_dropdown` rule — it would override deliberately-unstyled dropdowns elsewhere.
- **Expression string literals** cannot use `\u` escapes — embed the literal middot `·` (U+00B7) directly (matches `OpenBasketRow`, which renders it correctly). Files are UTF-8; never reintroduce the Windows-codepage double-encoding.
- **When writing multi-line Jython or expressions INTO `view.json` strings**, apply the Designer serialization convention: newlines → `\n`, tabs → `\t` (event/method bodies start with a leading `\t`), quotes → `\"`, and `=`→`=`, `<`→`<`, `>`→`>`, `&`→`&`. The readable code in this plan is the intent; escape it on write.
- **No business logic in Python entity scripts.** The overflow orchestration lives in the *view* `customMethod` (UI flow the operator explicitly confirms), not in a `BlueRidge.*` entity script; quantity/eligibility rules stay in SQL.
- **JDBC/FDS-11-011:** no new procs here; the one proc edit keeps its single result set.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql` | Breakdown read proc — add `ItemId` | Modify |
| `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql` | Add `ItemId` to the 3 INSERT-EXEC temp tables + assert | Modify |
| `…/Components/PlantFloor/DieCastEntry/CavityLotRow/view.json` | Mojibake fix + column sizing + `pf-field-select` on scrap dropdowns | Modify |
| `…/Components/Popups/DieCastOverflowRow/{view.json,resource.json}` | One overflow-cavity row: LTT input, emits `overflowLttChanged` | **New** |
| `…/Components/Popups/DieCastOverflow/{view.json,resource.json}` | Overflow popup: repeater + Fill/Overfill/Cancel | **New** |
| `Core/…/BlueRidge/Common/Util/code.py` | `allLttsPresent` helper for the popup's Fill-button enable | Modify |
| `…/Views/ShopFloor/DieCastBody/view.json` | Tab restructure, Subtitle mojibake, `activeTab`, `pf-field-select` on its dropdowns, overflow wiring | Modify |

Perspective paths are under `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/`.

---

## Task 1: Breakdown proc returns `ItemId`

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql`
- Test: `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql`

**Interfaces:**
- Produces: `Workorder.DieCast_GetShiftOutputBreakdown` result set gains a trailing `ItemId BIGINT` column. `view.custom.breakdown` rows (raw proc rows) therefore carry key `ItemId`, consumed by Task 5's `submitShiftOutput`.

- [ ] **Step 1: Add the `ItemId` column + assertion to the test (RED)**

In `030_ShiftOutput_Record.sql`, append `, ItemId BIGINT` to **all three** temp-table declarations (`@B` ~line 137, `@B2` ~line 277, `@B3` ~line 301). Example for `@B`:

```sql
DECLARE @B TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT);
```

Then, immediately after the existing `[Breakdown] prior good = 0` assertion (~line 151), add:

```sql
DECLARE @bItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM @B WHERE LotId=@Lot);
DECLARE @bItemExpected NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] ItemId returned matches the lot''s item', @Expected=@bItemExpected, @Actual=@bItem;
```

- [ ] **Step 2: Run the test — verify it FAILS**

```bash
pwsh -File sql/tests/Run-Tests.ps1 -Filter 0045_DieCast_Lifecycle
```
Expected: the `030` file errors on the first `INSERT INTO @B EXEC …` with *"Column name or number of supplied values does not match table definition"* (temp table now has 9 columns, proc still returns 8).

- [ ] **Step 3: Add `ItemId` to the proc (GREEN)**

In `R__Workorder_DieCast_GetShiftOutputBreakdown.sql`: add `l.ItemId` to the `Lots` CTE SELECT list, and add `lo.ItemId AS ItemId` as the **last** column of the final SELECT (after `MaxHeadroom`, before `FROM Lots lo`). Concretely:

CTE (was `SELECT l.Id AS LotId, l.LotName, l.ToolCavityId, l.PieceCount, l.MaxPieceCount,`):
```sql
        SELECT l.Id AS LotId, l.LotName, l.ToolCavityId, l.ItemId, l.PieceCount, l.MaxPieceCount,
```
Final SELECT — keep `MaxHeadroom`, append `ItemId`:
```sql
        CASE WHEN lo.MaxPieceCount IS NULL THEN 2147483647 ELSE lo.MaxPieceCount - lo.PieceCount END AS MaxHeadroom,
        lo.ItemId AS ItemId
```

- [ ] **Step 4: Apply the repeatable migration to the test DB, run the test — verify PASS**

```bash
pwsh -File sql/tests/Run-Tests.ps1 -Filter 0045_DieCast_Lifecycle
```
Expected: all `[Breakdown]`, `[Record]`, `[MultiLot]`, `[DefectCode]` assertions PASS, including the new `[Breakdown] ItemId returned matches the lot's item`. (`Run-Tests.ps1` applies repeatable migrations to `MPP_MES_Test` before running.)

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql
git commit -m "feat(diecast): breakdown proc returns ItemId for overflow re-open"
```

---

## Task 2: `CavityLotRow` — mojibake fix + uniform sizing

**Files:**
- Modify: `…/Components/PlantFloor/DieCastEntry/CavityLotRow/view.json`

**Interfaces:** none new (presentation only).

- [ ] **Step 1: Fix the reference-label mojibake**

Find the `ReferenceLabel` component's `props.text` expression (currently contains `"  Ã‚Â·  headroom "`). Replace the mojibake middot run with a clean literal `·` so the expression reads:

```
"prior " + toStr({view.params.priorGoodThisShift}) + if({view.params.maxHeadroom} < 2147483647, "  ·  headroom " + toStr({view.params.maxHeadroom}), "")
```

(On write, `<` becomes `<`; the middot stays a literal `·`.)

- [ ] **Step 2: Apply the existing sizing class to the scrap dropdowns + fix columns**

- `ScrapDefect1` / `ScrapDefect2` / `ScrapDefect3` dropdowns: set `props.style.classes` to `"pf-field-select"` (they are currently class-less — this is the height fix, reusing the existing class) and add `"minWidth": "180px"` to the same `props.style` so the placeholder never wraps.
- `GoodBlock` (`position.basis`): change `"110px"` → `"120px"`, keep `shrink:0`.
- `ReferenceLabel`: add `position: { "basis": "150px", "shrink": 0 }` so the "prior/headroom" column is a fixed width across rows.

- [ ] **Step 3: Scan + visual verify**

```bash
pwsh -File scan.ps1
```
On the Die Cast screen, Compute a breakdown with ≥2 open cavities. Confirm: the "prior … · headroom …" text renders with a clean middot (no `Ã…`); Good input / reference / scrap columns line up across all cavity rows; scrap dropdowns are single-line and the same height as the Good input (44px in DevTools).

- [ ] **Step 4: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastEntry/CavityLotRow/view.json"
git commit -m "fix(diecast): CavityLotRow middot mojibake + uniform dropdown/column sizing"
```

---

## Task 3: `DieCastOverflow` popup (+ row sub-view)

**Files:**
- Create: `…/Components/Popups/DieCastOverflowRow/view.json`
- Create: `…/Components/Popups/DieCastOverflowRow/resource.json`
- Create: `…/Components/Popups/DieCastOverflow/view.json`
- Create: `…/Components/Popups/DieCastOverflow/resource.json`
- Modify: `Core/…/BlueRidge/Common/Util/code.py` (add `allLttsPresent`)

**Interfaces:**
- Consumes: opened by Task 5 with `params = {overflow: [ {lotId, lotName, cavityNumber, headroom, good, remainder} … ], replyMessage: "dieCastOverflowResult", popupId: "mpp-diecast-overflow"}`.
- Produces: fires page-scoped `replyMessage` with one of `{action:"fill", ltts:{ "<lotId>": "<ltt>" }}`, `{action:"overfill"}`, `{action:"cancel"}`, then closes itself. New `BlueRidge.Common.Util.allLttsPresent(ltts, expectedCount) -> bool`.

- [ ] **Step 1: Create both `resource.json` files**

Copy an existing popup's resource.json (`…/Components/Popups/ConfirmAction/resource.json`) verbatim into each new folder (`DieCastOverflow/`, `DieCastOverflowRow/`). Shape:

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [ "view.json" ],
  "attributes": { "lastModification": { "actor": "claude", "timestamp": "2026-07-31T00:00:00Z" }, "lastModificationSignature": "" }
}
```

- [ ] **Step 2: Create `DieCastOverflowRow/view.json`**

```jsonc
{
  "custom": { "ltt": "" },
  "params": {
    "lotId": null, "lotName": "", "cavityNumber": "",
    "headroom": 0, "good": 0, "remainder": 0
  },
  "propConfig": {
    "params.lotId":        { "paramDirection": "input" },
    "params.lotName":      { "paramDirection": "input" },
    "params.cavityNumber": { "paramDirection": "input" },
    "params.headroom":     { "paramDirection": "input" },
    "params.good":         { "paramDirection": "input" },
    "params.remainder":    { "paramDirection": "input" }
  },
  "props": { "defaultSize": { "height": 84, "width": 520 } },
  "root": {
    "type": "ia.container.flex", "meta": { "name": "root" },
    "props": { "direction": "column", "style": { "classes": "pf-inventory-row", "gap": "6px" } },
    "children": [
      {
        "type": "ia.display.label", "meta": { "name": "Desc" },
        "propConfig": { "props.text": { "binding": { "type": "expr", "config": {
          "expression": "\"Cavity \" + toStr({view.params.cavityNumber}) + \"  ·  \" + {view.params.lotName} + \" — basket full. Submitting \" + toStr({view.params.good}) + \" pc: \" + toStr({view.params.headroom}) + \" fits, \" + toStr({view.params.remainder}) + \" overflow.\""
        } } } },
        "props": { "text": "", "style": { "fontWeight": 600 } }
      },
      {
        "type": "ia.input.text-field", "meta": { "name": "LttInput" },
        "propConfig": { "props.text": { "binding": { "type": "property", "config": {
          "bidirectional": true, "path": "view.custom.ltt" } } } },
        "props": { "placeholder": "Scan new LTT for the overflow basket",
                   "style": { "classes": "pf-field-input-mono" } },
        "events": { "dom": { "onBlur": { "type": "script", "scope": "G", "config": {
          "script": "\tsystem.perspective.sendMessage(\"overflowLttChanged\", payload={\"lotId\": self.view.params.lotId, \"ltt\": self.view.custom.ltt}, scope=\"page\")"
        } } } }
      }
    ]
  }
}
```

- [ ] **Step 3: Create `DieCastOverflow/view.json`**

```jsonc
{
  "custom": { "ltts": {} },
  "params": { "overflow": [], "replyMessage": "dieCastOverflowResult", "popupId": "mpp-diecast-overflow" },
  "propConfig": {
    "params.overflow":     { "paramDirection": "input" },
    "params.replyMessage": { "paramDirection": "input" },
    "params.popupId":      { "paramDirection": "input" }
  },
  "props": { "defaultSize": { "height": 420, "width": 560 } },
  "root": {
    "type": "ia.container.flex", "meta": { "name": "root" },
    "props": { "direction": "column", "style": { "classes": "pf-panel", "gap": "12px", "padding": "18px" } },
    "children": [
      { "type": "ia.display.label", "meta": { "name": "Title" },
        "props": { "text": "Basket capacity exceeded", "style": { "classes": "pf-panel-header", "fontSize": "18px", "fontWeight": 700 } } },
      { "type": "ia.display.label", "meta": { "name": "Sub" },
        "props": { "text": "One or more baskets would exceed their size. Scan a new LTT per cavity to fill the current basket, release it, and roll the remainder into a new basket — or overfill the baskets and continue.",
                   "style": { "classes": "pf-kpi-sub" } } },
      { "type": "ia.display.flex-repeater", "meta": { "name": "Rows" },
        "position": { "basis": "0", "grow": 1 },
        "propConfig": { "props.instances": { "binding": { "type": "property",
          "config": { "path": "view.params.overflow" },
          "transforms": [ { "type": "script", "code": "\trows = BlueRidge.Common.Util.extractQualifiedValues(value) or []\n\treturn [{\"lotId\": r.get(\"lotId\"), \"lotName\": r.get(\"lotName\") or \"\", \"cavityNumber\": r.get(\"cavityNumber\") or \"\", \"headroom\": r.get(\"headroom\") or 0, \"good\": r.get(\"good\") or 0, \"remainder\": r.get(\"remainder\") or 0} for r in rows]" } ] } } },
        "props": { "direction": "column", "path": "BlueRidge/Components/Popups/DieCastOverflowRow",
                   "elementPosition": { "basis": "auto", "shrink": 0 },
                   "style": { "gap": "8px", "overflowY": "auto" },
                   "useDefaultViewHeight": false, "useDefaultViewWidth": false } },
      { "type": "ia.container.flex", "meta": { "name": "Actions" },
        "position": { "shrink": 0 },
        "props": { "justify": "flex-end", "alignItems": "center", "style": { "gap": "10px", "paddingTop": "6px" } },
        "children": [
          { "type": "ia.input.button", "meta": { "name": "OverfillButton" },
            "props": { "text": "Overfill baskets", "style": { "classes": "pf-btn pf-btn-danger" } },
            "events": { "component": { "onActionPerformed": { "type": "script", "scope": "G", "config": {
              "script": "\tself.view.getChild(\"root\").reply(\"overfill\")" } } } } },
          { "type": "ia.input.button", "meta": { "name": "FillButton" },
            "propConfig": { "props.enabled": { "binding": { "type": "expr", "config": {
              "expression": "runScript(\"BlueRidge.Common.Util.allLttsPresent\", 0, {view.custom.ltts}, len({view.params.overflow}))" } } } },
            "props": { "text": "Fill, release & continue", "style": { "classes": "pf-btn pf-btn-primary" } },
            "events": { "component": { "onActionPerformed": { "type": "script", "scope": "G", "config": {
              "script": "\tself.view.getChild(\"root\").reply(\"fill\")" } } } } }
        ] }
    ],
    "events": { "component": {}, "dom": {}, "system": {} },
    "scripts": { "customMethods": [
      { "name": "reply", "params": [ "action" ], "script": "\tpayload = {\"action\": action}\n\tif action == \"fill\":\n\t\tpayload[\"ltts\"] = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.ltts) or {}\n\tsystem.perspective.sendMessage(self.view.params.replyMessage, payload=payload, scope=\"page\")\n\tsystem.perspective.closePopup(self.view.params.popupId)" }
    ], "messageHandlers": [
      { "messageType": "overflowLttChanged", "pageScope": true, "sessionScope": false, "viewScope": false,
        "script": "\tm = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.ltts) or {}\n\tm = dict(m)\n\tm[\"%s\" % payload.get(\"lotId\")] = (payload.get(\"ltt\") or \"\").strip()\n\tself.view.custom.ltts = m" }
    ] }
  }
}
```

- [ ] **Step 4: Add the `allLttsPresent` helper to `Common.Util`**

Add to `ignition/projects/Core/ignition/script-python/BlueRidge/Common/Util/code.py` (call `extractQualifiedValues` bare — same module, no import):

```python
def allLttsPresent(ltts, expectedCount):
    """True when the overflow-popup LTT map holds `expectedCount` non-blank
       entries (one scanned LTT per overflowing cavity). Enables the popup's
       Fill button. Returns bool."""
    m = extractQualifiedValues(ltts) or {}
    filled = [v for v in m.values() if v is not None and ("%s" % v).strip() != ""]
    try:
        return len(filled) >= int(expectedCount)
    except (ValueError, TypeError):
        return False
```

- [ ] **Step 5: Scan + smoke the popup render**

```bash
pwsh -File scan.ps1
```
In Designer open `DieCastOverflow`, set its `params.overflow` preview to a 2-element list of `{lotId, lotName, cavityNumber, headroom, good, remainder}`; confirm two rows render with the description + LTT field, that filling both LTTs enables "Fill, release & continue", and clearing one disables it again. No DB calls here.

- [ ] **Step 6: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieCastOverflow" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieCastOverflowRow" ignition/projects/Core/ignition/script-python/BlueRidge/Common/Util/code.py
git commit -m "feat(diecast): overflow-resolution popup + row sub-view + allLttsPresent helper"
```

---

## Task 4: `DieCastBody` — tab restructure, Subtitle mojibake, `activeTab`, dropdown sizing

**Files:**
- Modify: `…/Views/ShopFloor/DieCastBody/view.json`

**Interfaces:**
- Consumes: existing view-level `customMethods` and `view.custom.*` (unchanged by the move).
- Produces: three-tab layout; new `view.custom.activeTab` (int, default 0). The `OpenPanel`, `ShiftOutputPanel`, and `CurrentlyOpenPanel` containers keep their `meta.name`s (moved, not renamed) so later addressing works.

> **Do this whole task in one editing pass** (single file); scan once at the end. Ask the human to close `DieCastBody` in Designer first.

- [ ] **Step 1: Fix the Subtitle mojibake**

In the `Subtitle` component's `props.text` expression, replace both mojibake middot runs (`Ãƒâ€šÃ‚Â·`) with a clean literal `·`:

```
{session.custom.cell.name} + "  ·  SHARED TERMINAL  ·  " + if(isNull({view.custom.activeTool.ToolCode}) || {view.custom.activeTool.ToolCode} = "", "No die mounted", "Tool " + {view.custom.activeTool.ToolCode})
```

(On write: `=` → `=`; middot literal.)

- [ ] **Step 2: Add the `activeTab` custom prop**

In the top-level `custom` block, add `"activeTab": 0`.

- [ ] **Step 3: Apply `pf-field-select` to the class-less dropdowns**

For uniform height with the text fields, add `"classes": "pf-field-select"` to `props.style` of these dropdowns (preserve any existing inline `width`): `ItemDropdown`, `ShiftDropdown`, `CavityDropdown` (keep its `width:"100%"`), `ShotLossReasonDropdown`, `CellPickerDropdown` (keep its `width:"300px"`).

- [ ] **Step 4: Wrap the three panels in a tab container inside a new `MainRow`**

`root.children[2]` is the `Body` flex container holding, in order: `OpenPanel`, `ShiftOutputPanel`, `CurrentlyOpenPanel`, `RightRail`. Replace `Body` with a `MainRow` holding a `TabContainer` (3 tabs) + the existing `RightRail`. Move the three panel containers **verbatim** (do not edit their internals beyond the position change below) into the tab container as children[0..2]; move `RightRail` verbatim as `MainRow`'s second child.

New `MainRow` node (panels shown as placeholders — paste the existing container objects unchanged):

```jsonc
{
  "type": "ia.container.flex",
  "meta": { "name": "MainRow" },
  "position": { "grow": 1 },
  "props": { "style": { "gap": "16px" } },
  "children": [
    {
      "type": "ia.container.tab",
      "meta": { "name": "TabContainer" },
      "position": { "basis": "0", "grow": 1 },
      "propConfig": { "props.currentTabIndex": { "binding": { "type": "property",
        "config": { "bidirectional": true, "path": "view.custom.activeTab" } } } },
      "props": {
        "currentTabIndex": 0,
        "menuType": "modern",
        "tabs": [
          { "text": "Open Basket", "runWhileHidden": true, "disabled": false },
          { "text": "Record Shift Output", "runWhileHidden": true, "disabled": false },
          { "text": "Lot Release", "runWhileHidden": true, "disabled": false }
        ],
        "menuStyle": { "classes": "tab-strip" },
        "contentStyle": { "classes": "tab-content-fill" },
        "tabStyle": {
          "active": { "classes": "tab-item tab-item-active" },
          "inactive": { "classes": "tab-item" },
          "disabled": { "classes": "tab-item" }
        }
      },
      "children": [
        /* <<< existing OpenPanel container object, moved verbatim >>> */
        /* <<< existing ShiftOutputPanel container object, moved verbatim >>> */
        /* <<< existing CurrentlyOpenPanel container object, moved verbatim >>> */
      ]
    }
    /* <<< existing RightRail container object, moved verbatim >>> */
  ]
}
```

Notes:
- Tab child order **must** match `tabs[]`: OpenPanel, ShiftOutputPanel, CurrentlyOpenPanel.
- On each moved panel, **remove** the old row-width `position` (`OpenPanel` `basis:"380px"`; `ShiftOutputPanel` `basis:"620px",grow:1`; `CurrentlyOpenPanel` `basis:"360px"`) and set each to `position: { "grow": 1 }` so it fills the tab content. Keep `RightRail`'s `position.basis:"320px"`.
- Drop the old `Body` container's `wrap:"wrap"`.

- [ ] **Step 5: Fix the `clearOpenDraft` focus path**

`clearOpenDraft` focuses the LTT input via `self.getChild("Body").getChild("OpenPanel")…`. `Body` no longer exists. Update to:

```python
	self.getChild("MainRow").getChild("TabContainer").getChild("OpenPanel").getChild("LttField").getChild("LttInput").focus()
```

(Keep the surrounding `try/except`. Other methods use `self.view.rootContainer.*` / `self.view.custom.*` and are unaffected.)

- [ ] **Step 6: Scan + verify the restructure**

```bash
pwsh -File scan.ps1
```
Reopen `DieCastShared` and `DieCastDedicated` in Designer (they embed `DieCastBody`). In a session confirm: header + Active Cell + KPI right rail are persistent; three tabs switch correctly; Subtitle shows clean `·`; every dropdown matches the text-field height; Open, Compute/Preview, shot loss, Release, Void, operator switch, cell picker still work; Clear after Open returns focus to the LTT field.

- [ ] **Step 7: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/DieCastBody/view.json"
git commit -m "feat(diecast): tab restructure (Open/Record/Release) + KPI rail + Subtitle mojibake + dropdown sizing"
```

---

## Task 5: `DieCastBody` — overflow gate wiring

**Files:**
- Modify: `…/Views/ShopFloor/DieCastBody/view.json`

**Interfaces:**
- Consumes: Task 1's `ItemId` on breakdown rows; Task 3's `DieCastOverflow` popup + reply contract; existing `BlueRidge.Lots.Lot.releaseDieCast`/`openDieCast` and `BlueRidge.Workorder.DieCast.recordShiftOutput`.
- Produces: `submitShiftOutput` gates on overflow; new `resolveOverflow(action, ltts)` + `_afterSubmit()` methods; new `view.custom.pendingSubmit`; new `dieCastOverflowResult` message handler.

- [ ] **Step 1: Add `pendingSubmit` custom prop**

In the top-level `custom` block add `"pendingSubmit": {}`.

- [ ] **Step 2: Replace `submitShiftOutput` with the overflow-aware version** (readable form — escape on write)

```python
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.breakdown) or []
	entries = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.breakdownEntries) or {}
	tool = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.activeTool) or {}
	cell = BlueRidge.Common.Util.extractQualifiedValues(self.session.custom.cell) or {}
	lines = []
	overflow = []
	for r in rows:
		r = r or {}
		if not r.get("IsOpen"):
			continue
		lotId = r.get("LotId")
		e = entries.get("%s" % lotId) or {}
		good = BlueRidge.Common.Util.toIntOrNone(e.get("good"))
		if good is None:
			good = BlueRidge.Common.Util.toIntOrNone(r.get("ProposedGood")) or 0
		scrapLines = []
		for sl in (BlueRidge.Common.Util.extractQualifiedValues(e.get("scrapLines")) or []):
			sl = sl or {}
			d = sl.get("defectCodeId")
			q = BlueRidge.Common.Util.toIntOrNone(sl.get("quantity"))
			if d and q:
				scrapLines.append({"defectCodeId": d, "quantity": q})
		lines.append({"lotId": lotId, "pieceDelta": good, "scrapLines": scrapLines})
		h = BlueRidge.Common.Util.toIntOrNone(r.get("MaxHeadroom"))
		if h is not None and h < 2147483647 and good > h:
			overflow.append({"lotId": lotId, "lotName": r.get("LotName") or "",
				"cavityNumber": r.get("CavityNumber") or "", "toolCavityId": r.get("ToolCavityId"),
				"itemId": r.get("ItemId"), "headroom": h, "good": good,
				"remainder": good - h, "scrapLines": scrapLines})
	if not lines:
		BlueRidge.Common.Notify.toast("Nothing to submit", "Compute a breakdown first (enter gross shots and press Compute).", "warning")
		return
	term = None
	try:
		term = self.session.custom.terminal.terminalLocationId
	except:
		term = None
	if overflow:
		self.view.custom.pendingSubmit = {"lines": lines, "overflow": overflow,
			"shiftId": self.view.custom.selectedShiftId, "toolId": tool.get("ToolId"),
			"cellLocationId": cell.get("locationId"), "terminalLocationId": term}
		system.perspective.openPopup("mpp-diecast-overflow",
			"BlueRidge/Components/Popups/DieCastOverflow",
			params={"replyMessage": "dieCastOverflowResult", "popupId": "mpp-diecast-overflow", "overflow": overflow},
			modal=True, showCloseIcon=True)
		return
	data = {"shiftId": self.view.custom.selectedShiftId, "toolId": tool.get("ToolId"), "lines": lines, "shotLoss": []}
	result = BlueRidge.Workorder.DieCast.recordShiftOutput(data, appUserId=self.session.custom.appUserId, terminalLocationId=term)
	BlueRidge.Common.Ui.notifyResult(result, successTitle="Shift output recorded")
	if result and result.get("Status"):
		self._afterSubmit()
```

- [ ] **Step 3: Add `_afterSubmit` customMethod**

```python
	self.view.custom.pendingSubmit = {}
	self.view.custom.grossShots = ""
	self.view.custom.breakdown = []
	self.view.custom.breakdownEntries = {}
	self.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1
```

- [ ] **Step 4: Add `resolveOverflow(action, ltts)` customMethod**

```python
	ps = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.pendingSubmit) or {}
	if not ps:
		return
	lines = BlueRidge.Common.Util.extractQualifiedValues(ps.get("lines")) or []
	overflow = BlueRidge.Common.Util.extractQualifiedValues(ps.get("overflow")) or []
	shiftId = ps.get("shiftId")
	toolId = ps.get("toolId")
	cellId = ps.get("cellLocationId")
	term = ps.get("terminalLocationId")
	appUserId = self.session.custom.appUserId
	if action == "cancel":
		self.view.custom.pendingSubmit = {}
		return
	if action == "overfill":
		data = {"shiftId": shiftId, "toolId": toolId, "lines": lines, "shotLoss": []}
		result = BlueRidge.Workorder.DieCast.recordShiftOutput(data, appUserId=appUserId, terminalLocationId=term)
		BlueRidge.Common.Ui.notifyResult(result, successTitle="Shift output recorded (baskets overfilled)")
		if result and result.get("Status"):
			self._afterSubmit()
		return
	ltts = BlueRidge.Common.Util.extractQualifiedValues(ltts) or {}
	overLotIds = set(o.get("lotId") for o in overflow)
	nonOverflow = [ln for ln in lines if ln.get("lotId") not in overLotIds]
	if nonOverflow:
		r0 = BlueRidge.Workorder.DieCast.recordShiftOutput(
			{"shiftId": shiftId, "toolId": toolId, "lines": nonOverflow, "shotLoss": []},
			appUserId=appUserId, terminalLocationId=term)
		BlueRidge.Common.Ui.notifyResult(r0, successTitle="Cavities within capacity recorded")
		if not (r0 and r0.get("Status")):
			return
	for o in overflow:
		oldLot = o.get("lotId")
		newLtt = (ltts.get("%s" % oldLot) or ltts.get(oldLot) or "")
		newLtt = ("%s" % newLtt).strip()
		rel = BlueRidge.Lots.Lot.releaseDieCast({"lotId": oldLot, "finalPieceDelta": o.get("headroom"),
			"scrapLines": o.get("scrapLines") or [], "shiftId": shiftId,
			"appUserId": appUserId, "terminalLocationId": term})
		BlueRidge.Common.Ui.notifyResult(rel, successTitle="Basket " + (o.get("lotName") or "") + " filled + released")
		if not (rel and rel.get("Status")):
			return
		opened = BlueRidge.Lots.Lot.openDieCast({"itemId": o.get("itemId"), "currentLocationId": cellId,
			"toolId": toolId, "toolCavityId": o.get("toolCavityId"), "lotName": newLtt,
			"appUserId": appUserId, "terminalLocationId": term})
		BlueRidge.Common.Ui.notifyResult(opened, successTitle="New basket " + newLtt + " opened")
		if not (opened and opened.get("Status")):
			return
		newLot = opened.get("NewId")
		rem = BlueRidge.Workorder.DieCast.recordShiftOutput(
			{"shiftId": shiftId, "toolId": toolId,
			 "lines": [{"lotId": newLot, "pieceDelta": o.get("remainder"), "scrapLines": []}], "shotLoss": []},
			appUserId=appUserId, terminalLocationId=term)
		BlueRidge.Common.Ui.notifyResult(rem, successTitle="Remainder recorded to " + newLtt)
		if not (rem and rem.get("Status")):
			return
	self._afterSubmit()
```

- [ ] **Step 5: Add the `dieCastOverflowResult` message handler**

Add to the view's `messageHandlers` (mirror the `releaseConfirmResult` entry — page-scoped):

```json
{
  "messageType": "dieCastOverflowResult",
  "pageScope": true, "sessionScope": false, "viewScope": false,
  "script": "\tif payload:\n\t\tself.resolveOverflow(payload.get(\"action\"), payload.get(\"ltts\"))"
}
```

- [ ] **Step 6: Scan + end-to-end smoke (dev DB)**

```bash
pwsh -File scan.ps1
```
Using the dev DB (seed a capped-`MaxLotSize` item; see `project_mpp_plant_floor_smoke_seed`), open a basket on a cavity, drive its `PieceCount` near the cap, enter a gross that overflows that cavity, Submit:
- **No overflow** (small gross): submits directly, one write, KPIs update — unchanged.
- **Overflow → Fill**: popup lists the overflow cavity; scan a new LTT; "Fill, release & continue" → basket 1 released at exactly cap, new basket opened on the scanned LTT with the remainder, KPIs sum correctly, both lots visible on the Lot Release tab.
- **Overflow → Overfill**: single basket exceeds cap (one write), no new basket.
- **Multi-cavity overflow**: one LTT field per overflowing cavity; Fill button disabled until all entered.
- **Cancel**: nothing written; re-Submit still available.

- [ ] **Step 7: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/DieCastBody/view.json"
git commit -m "feat(diecast): basket-overflow gate — fill+release+new-LTT or overfill"
```

---

## Final verification

- [ ] Run `pwsh -File sql/tests/Run-Tests.ps1 -Filter 0045_DieCast_Lifecycle` — all green.
- [ ] Full screen pass on `DieCastShared` (cell picker) and `DieCastDedicated` (fixed cell): three tabs, persistent KPI rail, clean middots, uniform input heights, overflow popup both paths, no console errors (DevTools).
- [ ] `git log --oneline` shows Tasks 1–5 as discrete commits on `jacques/working`.
- [ ] Push: `git push origin jacques/working`.

## Notes / risks (carried from the spec)

- **Overflow fill is not one transaction** — each of release/open/record is individually atomic; a mid-sequence failure surfaces via `notifyResult` and stops, leaving a consistent, operator-recoverable state. Accepted trade-off of Option A.
- **New basket may itself exceed cap** — the full remainder goes into one new basket; no recursive splitting (documented, matches operator's mental model).
- **File-edit boundary** — `DieCastBody`/`CavityLotRow` are existing views; edit with Designer closed, scan, reopen. New popups are file-safe.
