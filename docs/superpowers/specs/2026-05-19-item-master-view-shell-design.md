# Item Master — View Shell + Add Item Modal (Phase 1 of 8)

**Date:** 2026-05-19
**Status:** Approved — ready for implementation plan
**Scope:** First-pass build of the Configuration Tool Item Master surface. Phase 1 = visual shell with dummy data, no DB wiring, no scripts. Later phases (2–8) wire reads, writes, and the versioned Routes/BOMs workflows.

---

## 1. Goals

Stand up the **Item Master** page in the Configuration Tool as a fully laid-out visual surface that mirrors `mockup/index.html` § "SCREEN: Item Master" (lines 308–860) and the `+Add Item` modal (lines 2629–2715), backed by realistic dummy data in `view.custom` so that the future wire passes (Phases 2–8) can plug in real data and behaviors without restructuring the views.

Phase 1 deliverables:

- Page route `/items` mounted at `BlueRidge/Views/Parts/ItemMaster`, page title `"Item Master"`.
- Sidebar navigation entry under Parts → Item Master.
- ItemMaster page shell (left list panel + right detail area with always-visible item details header + 5-tab container).
- Each of the 5 tabs implemented as its own **embedded view** under `Components/Parts/ItemMaster/` for cleanliness and per-tab phase ownership.
- `+Add Item` modal popup view shell.
- `view.custom` state model populated with realistic dummy data mirroring the mockup's 5G0 Front Cover example.
- All form inputs bound bidirectionally to `editDraft.<slice>.<field>` so the editDraft pattern is wired end-to-end.
- Save / Deprecate / +Add Item Create / New Version buttons present but fire a `Common.Notify.toast` saying "Not wired yet."

---

## 2. Non-Goals (Deliberately Phase 1)

| Capability | Deferred to phase |
|---|---|
| Read item list / item details from DB | Phase 2 |
| Item Save / Deprecate procs + wire | Phase 3 |
| `+Add Item` Create flow wired (proc + entity script + popup → list refresh) | Phase 3 |
| Container Config save proc + wire | Phase 4 |
| Routes Draft/Published versioning workflow (toggle, +Add Step, Move up/down, Publish, Discard) | **Phase 5 — own design doc + plan** |
| BOMs Draft/Published versioning workflow | **Phase 6 — own design doc + plan** |
| Quality Specs cross-link (read-only join) | Phase 7 |
| Eligibility (`Parts.ItemLocation`) editor + cascade-aware grid | Phase 8 |
| Per-tab dirty indicator coordination across the parent | Bundled with Phases 3–4 (the first phase that actually saves) |
| `Audit.ConfigLog` writes on save | Bundled with each save phase |

Phase 1 deliberately renders only the **Published view** of Routes and BOMs (static read-only table). The Draft toggle, +Add Step / +Add Component buttons, Move-up/down arrows, Publish, Discard Draft, Effective Date picker, version-selector dropdown — all of those exist visually in the mockup but are **out of Phase 1 scope** because they represent substantive interactive sub-systems with their own validation rules (see FDS-03-005, FDS-03-010, conventions pack §"Versioned-entity workflow"). Trying to scaffold them as "static for now" leaves half-finished interactions that confuse the Phase 5/6 builds.

---

## 3. Phased Workflow (Item Master Build Roadmap)

| Phase | Scope | Output |
|---|---|---|
| **1 (this doc)** | View shell, dummy data, +Add Item modal shell, nav entry | 7 new view files + page-config + sidebar update |
| 2 | Read paths: item list (left panel) + item-details bundle (right panel + Container Config tab) | NQs `parts/Item_List`, `Item_GetById`, `ContainerConfig_GetByItemId`; entity script `BlueRidge.Parts.Item` (`getAll`, `getOne`) |
| 3 | Item create / update / deprecate + Add Item modal wired | SP + NQ + script `Item_Add`, `Item_Update`, `Item_Deprecate`; modal Create button posts; list refresh on success |
| 4 | Container Config save | SP + NQ + script `ContainerConfig_Save`; in-tab Save extracted from page-level Save |
| 5 | **Routes versioning workflow** (Draft/Published/Deprecated lifecycle, +Add Step, Move up/down, Publish with EffectiveFrom validation, Discard) — has its own design doc | Many; covers `RouteTemplate`, `RouteStep`, `RouteTemplate_CreateNewVersion`, `RouteTemplate_Publish`, `RouteTemplate_Save`, `RouteTemplate_Deprecate`, `RouteTemplate_Discard` |
| 6 | **BOMs versioning workflow** (same lifecycle as Routes) — has its own design doc | Parallel surface to Phase 5 for `Bom` + `BomLine` |
| 7 | Quality Specs cross-link (read-only) | NQ `parts/QualitySpec_ListByItem`; entity-script helper |
| 8 | Eligibility (`ItemLocation`) editor with hierarchy-aware tier picker | SPs for `ItemLocation_Add`, `_Update`, `_Deprecate`; cascade-aware Area-filtered grid |

This roadmap is the **commitment for the Item Master surface**. Each future phase gets its own brainstorm + design doc + implementation plan; Phase 1 is the only one this doc covers.

---

## 4. Architecture

Phase 1 has no DB layer, no SQL, no scripts, no NQs. All state lives in `view.custom` on the parent (ItemMaster) and is fed to each embedded tab view through bidirectional `view.params.value` binding. Dummy data is baked into ItemMaster's `view.custom` defaults so the page renders fully populated on first load.

```
ItemMaster (page view)
  view.custom.items[]          ← dummy item list
  view.custom.selected         ← currently selected item bundle (meta + per-tab slices)
  view.custom.editDraft        ← in-flight edits (initially equal to selected)
  view.custom.itemTypes[]      ← dummy seed
  view.custom.uoms[]           ← dummy seed
  view.custom.activeTab        ← "containerConfig" by default
  view.custom.mode             ← "view" | "create" | "update"

        │ (param bidi: editDraft.containerConfig)
        ▼
  Components/Parts/ItemMaster/ContainerConfig
    view.params.value           (Object, bidirectional via embedded-view param binding)
    form fields bind to view.params.value.<field>

        │ (param: editDraft.routes — read-only slice; Phase 5 will introduce mutations)
        ▼
  Components/Parts/ItemMaster/Routes
    view.params.value           (Object — published version + steps[])

        │ (param: editDraft.boms — read-only slice; Phase 6)
        ▼
  Components/Parts/ItemMaster/Boms
    view.params.value           (Object — published version + lines[])

        │ (param: editDraft.qualitySpecs)
        ▼
  Components/Parts/ItemMaster/QualitySpecs
    view.params.value           (list[dict] of linked specs)

        │ (param: editDraft.eligibility)
        ▼
  Components/Parts/ItemMaster/Eligibility
    view.params.value           (Object — filterArea + rows[])
```

Each tab Embedded View in the parent is **always mounted**, gated by `position.display = "{view.custom.activeTab} = '<tab-key>'"`. Switching tabs doesn't unmount — local UI state (scroll, focus) survives. (Five always-mounted embedded views is acceptable here; they're cheap and the user will tab back and forth while editing.)

Add Item modal is a **separate popup view** opened via `system.perspective.openPopup(id="mpp-add-item", view="BlueRidge/Components/Popups/AddItem", modal=True)`. Its own `view.custom.draft` is a fresh empty item; Cancel and Create both close without writing in Phase 1.

---

## 5. File Inventory

7 new view files + 2 config edits.

```
ignition/projects/MPP_Config/com.inductiveautomation.perspective/
  page-config/config.json                                                        [EDIT]
    → add "/items" entry pointing at BlueRidge/Views/Parts/ItemMaster

  views/BlueRidge/Views/Containers/Sidebar/view.json                             [EDIT]
    → add "Parts" group + "Item Master" link

  views/BlueRidge/Views/Parts/ItemMaster/                                        [NEW]
    resource.json
    view.json

  views/BlueRidge/Components/Parts/ItemMaster/                                   [NEW folder]
    ContainerConfig/
      resource.json
      view.json
    Routes/
      resource.json
      view.json
    Boms/
      resource.json
      view.json
    QualitySpecs/
      resource.json
      view.json
    Eligibility/
      resource.json
      view.json

  views/BlueRidge/Components/Popups/AddItem/                                     [NEW]
    resource.json
    view.json
```

**Naming convention note:** placing the per-tab views under `Components/Parts/ItemMaster/<TabName>` follows the existing precedent of `Components/Audit/TopRow` (sub-view grouped by the page that owns it). The `_<Name>` underscore-prefix convention from `07_conventions_and_antipatterns.md` is reserved for internals of a reusable `Components/<Name>` component; since ItemMaster lives in `Views/`, not `Components/`, the flat grouping under `Components/<Domain>/<Page>/` is the better fit and stays greppable.

---

## 6. ItemMaster Page Layout

```
root (ia.container.flex, direction: column, height: 100%)
├── TitleBar (flex row, basis: 48px)
│     Breadcrumb ("Parts › Item Master › 5G0 Front Cover")
│     DirtyIndicator (expr: editDraft != selected ? "● Unsaved changes" : "")
│     Spacer (grow:1)
│     AddItemButton ("+ Add Item")  → events.dom.onClick → popup open AddItem
│
└── Main (flex row, grow: 1)
    ├── LeftPanel (basis: 240px, shrink: 0, flex column)
    │     SearchInput (bidi: view.custom.search)
    │     TypeFilter (bidi: view.custom.typeFilter; options from itemTypes)
    │     ItemListScroll (grow:1, overflow-y:auto)
    │       FlexRepeater_Items (instances ← view.custom.items)
    │         each instance renders an item row:
    │           - selected styling via expr: instance.id == view.custom.selected.meta.Id
    │           - draft styling via expr: instance.isDraft
    │           - on click → set selected + editDraft + mode = "update"
    │
    └── DetailArea (grow:1, flex column)
        ├── DetailsHeader (basis: auto)
        │     SummaryRow (PartNumber — Description + ItemTypeBadge + Save + Deprecate)
        │     FieldRow 1: PartNumber (readonly in update mode), ItemType (readonly), UOM (editable)
        │     FieldRow 2: Description (text, wide), MacolaPartNumber (text)
        │     FieldRow 3: UnitWeight, WeightUOM, DefaultSubLotQty, PartsPerBasket (MaxLotSize)
        │
        └── TabContainer (grow:1, flex column)
            ├── TabStrip (flex row, basis: 36px)
            │     5 tab buttons: ContainerConfig | Routes | BOMs | Quality Specs | Eligibility
            │     each onClick → set view.custom.activeTab = "<key>"
            │     active styling via expr: view.custom.activeTab == "<key>"
            │
            └── TabPanels (grow:1, position:relative)
                ├── Embed_ContainerConfig  position.display ← activeTab == "containerConfig"
                ├── Embed_Routes           position.display ← activeTab == "routes"
                ├── Embed_Boms             position.display ← activeTab == "boms"
                ├── Embed_QualitySpecs     position.display ← activeTab == "qualitySpecs"
                └── Embed_Eligibility      position.display ← activeTab == "eligibility"

                Each Embed_X is ia.display.view with:
                  props.path     = "BlueRidge/Components/Parts/ItemMaster/<TabName>"
                  props.params.value  ← bidi bound to view.custom.editDraft.<slice>
```

### Row-click handler (inline, ≤3 lines, per conventions pack §"Efficiency hierarchy")

Pseudocode — exact implementation depends on whether the item list is rendered as a `ia.display.flex-repeater` (each row = sub-view, click handled on the row sub-view and surfaced upward via page-scoped message) or as an `ia.display.table` with row-click event. The implementation plan picks the mechanism; both end with these three writes on the parent ItemMaster view:

```python
# in the parent's message handler OR row sub-view click → message-back
self.view.custom.selected  = clickedItem            # full bundle from view.custom.items
self.view.custom.editDraft = dict(clickedItem)
self.view.custom.mode      = "update"
```

In Phase 1, since dummy items in the list carry the FULL bundle (meta + containerConfig + routes + boms + qualitySpecs + eligibility), this single assignment populates everything. Phase 2 will replace this with a `BlueRidge.Parts.Item.getOne(id)` call that hydrates the per-tab slices from the DB. If a per-row sub-view is needed, it lands as `Components/Parts/ItemMaster/ItemRow/` (8th view) and is wired with a page-scoped `itemRowClicked` message back to ItemMaster.

### Tab-switch handler

```python
# events.component.onActionPerformed on each tab button
self.view.custom.activeTab = "containerConfig"   # or routes, boms, qualitySpecs, eligibility
```

### Save / Deprecate handlers (placeholder)

```python
# events.component.onActionPerformed on Save button
BlueRidge.Common.Notify.toast("Not wired yet", "Item save will land in Phase 3.", "info", 5)
```

---

## 7. State Model

`view.custom` on ItemMaster:

```yaml
search:       ""                 # bidi from SearchInput; client-side filter on items list (future enhancement; Phase 1 input is wired but filter logic deferred)
typeFilter:   "All Types"        # bidi from TypeFilter
activeTab:    "containerConfig"  # "containerConfig" | "routes" | "boms" | "qualitySpecs" | "eligibility"
mode:         "update"           # "view" | "create" | "update"

items:        [                  # dummy seed — mirrors mockup left panel
  {id:1, partNumber:"5G0",     description:"Front Cover Assy",      itemTypeName:"Finished Good", typeBadge:"FG",   isDraft:false},
  {id:2, partNumber:"5G0-C",   description:"Front Cover Casting",   itemTypeName:"Component",      typeBadge:"COMP", isDraft:false},
  {id:3, partNumber:"PNA",     description:"Mounting Pin",          itemTypeName:"Component",      typeBadge:"COMP", isDraft:false},
  {id:4, partNumber:"6MA-HSG", description:"Cam Holder Housing",    itemTypeName:"Pass-Through",   typeBadge:"PT",   isDraft:true},
  {id:5, partNumber:"RPY",     description:"Assembly Set",          itemTypeName:"Finished Good",  typeBadge:"FG",   isDraft:false}
]

itemTypes:    ["Raw Material", "Component", "Sub-Assembly", "Finished Good", "Pass-Through"]
uoms:         ["EA", "LB", "KG"]

selected: { … same shape as editDraft … }      # baseline; dirty indicator compares editDraft vs this

editDraft:                                     # bound bidirectionally by all form fields + child tabs
  meta:
    Id:                  1
    PartNumber:          "5G0"
    Description:         "5G0 Front Cover Assembly"
    ItemTypeName:        "Finished Good"
    UomCode:             "EA"
    MacolaPartNumber:    "5G0-FC-001"
    UnitWeight:          3.25
    WeightUomCode:       "LB"
    DefaultSubLotQty:    24
    PartsPerBasket:      100      # MaxLotSize repurposed per data model v1.9
    CountryOfOrigin:     "US"     # FDS-03-001; not in mockup but in data model — kept in shape
    MaxParts:            500      # per FDS-03-019; not in mockup but in shape for future surface
  containerConfig:
    TraysPerContainer:   4
    PartsPerTray:        12
    IsSerialized:        true
    ClosureMethod:       "ByCount"
    TargetWeight:        null
    DunnageCode:         "RD-5G0F"
    CustomerCode:        "HONDA-5G0"
  routes:                            # Phase 1 = published only, no draft toggle
    publishedVersion: 2
    effectiveFrom:   "2026-01-15"
    steps: [
      {seq:1, areaName:"Die Cast",     templateLabel:"DC-5G0 v1 — Die Cast 5G0 Front Cover",   isRequired:true, dataFields:"DieInfo, CavityInfo, Weight, GoodCount, BadCount"},
      {seq:2, areaName:"Trim Shop",    templateLabel:"TRIM-5G0 v1 — Trim 5G0 Front Cover",     isRequired:true, dataFields:"Weight, GoodCount, BadCount"},
      {seq:3, areaName:"Machine Shop", templateLabel:"CNC-5G0 v1 — CNC Machining 5G0",         isRequired:true, dataFields:"GoodCount, BadCount"},
      {seq:4, areaName:"Prod Control", templateLabel:"ASSY-FRONT v1 — Assembly Front Cover",   isRequired:true, dataFields:"SerialNumber, MaterialVerification, GoodCount, BadCount"}
    ]
  boms:                              # Phase 1 = published only
    publishedVersion: 1
    effectiveFrom:   "2026-01-15"
    lines: [
      {seq:1, componentName:"Front Cover Casting", partNumber:"5G0-C", qtyPer:1, uom:"EA"},
      {seq:2, componentName:"Mounting Pin",        partNumber:"PNA",   qtyPer:2, uom:"EA"}
    ]
  qualitySpecs: [
    {specName:"5G0 Dimensional Spec",     activeVersion:"v2", statusLabel:"Active"},
    {specName:"5G0 Visual Inspection",    activeVersion:"v1", statusLabel:"Active"}
  ]
  eligibility:
    selectedArea: "Die Cast"
    rows: [
      {machineName:"DC Machine #3",  code:"DC-003", tonnage:"400 tons", eligible:true},
      {machineName:"DC Machine #7",  code:"DC-007", tonnage:"400 tons", eligible:true},
      {machineName:"DC Machine #12", code:"DC-012", tonnage:"400 tons", eligible:true},
      {machineName:"DC Machine #15", code:"DC-015", tonnage:"250 tons", eligible:false}
    ]
```

### Dummy data is realistic, not skeletal

Every field in the data model that appears in the Phase 2+ wire pass has a sample value here, even when it's not shown in the mockup (e.g., `CountryOfOrigin`, `MaxParts`). This keeps the state shape forward-compatible and lets us add UI for those fields later without restructuring `editDraft`.

### Dirty indicator

Expression binding on a label in TitleBar:

```
if({view.custom.editDraft} != {view.custom.selected}, '● Unsaved changes', '')
```

Mutating any form field (including any field inside an embedded tab) will flip this label — validates the round-trip through embedded-view param bidirectional binding without any save logic.

---

## 8. Tab View Details

Each tab view follows the same skeleton:

```
view.params:
  value:  Object       # paramDirection "input" on the child; parent supplies bidirectional binding
view.custom: {}        # empty in Phase 1 — all state lives on the parent
root (ia.container.flex):
  form fields / table bound to view.params.value.<field>
```

**Bidirectional propagation:** The parent's Embedded View component declares `props.params.value` with a binding of `type: property`, `path: view.custom.editDraft.<slice>`, `config.bidirectional: true`. When the child mutates `view.params.value.<field>` (via a form field's bidirectional binding), the change writes back through the binding to the parent's `editDraft.<slice>.<field>`. This is the Perspective-native mechanism for parent ↔ child editor state.

### Tab 1: ContainerConfig

Mirrors mockup §"Tab: Container Config" (lines 458–497) verbatim. Two field rows:
- Row 1: TraysPerContainer (number), PartsPerTray (number), IsSerialized (dropdown Yes/No, bound to boolean)
- Row 2: ClosureMethod (dropdown ByCount/ByWeight/ByVision), DunnageCode (text), CustomerCode (text)

`TargetWeight` (visible when `ClosureMethod = ByWeight` per data model) is **NOT** in the mockup; out of Phase 1 scope — the conditional-display logic for it lands when the wire pass surfaces it (Phase 4).

### Tab 2: Routes

Phase 1 shape: **published version only, read-only**, single static panel mirroring mockup lines 502–587 (`#routes-pub-panel`). One version-selector dropdown (visually present, no behavior beyond the static current option), Published badge, `New Version` button → toast "Not wired yet."

Table:
- 6 columns: #, Up/Down arrows (disabled in Phase 1 — Published rows aren't movable), Area, Operation Template, Required (checkbox, disabled), Data Collection
- Rows iterate `view.params.value.steps`
- Bottom caption: "Published — read-only. Click New Version to create a draft copy for editing."

Draft mode, +Add Step, +Add Step button, Move-up/down arrows on draft rows, Discard Draft / Publish buttons, Effective Date picker — **all deferred to Phase 5.**

### Tab 3: Boms

Same shape as Routes — published version only, read-only table, version selector + New Version button (toast). Columns: #, Up/Down (disabled), Component, Part Number, Qty, UOM. Rows iterate `view.params.value.lines`.

Draft workflow → **Phase 6**.

### Tab 4: QualitySpecs

Static linked-specs table per mockup lines 776–805. Columns: Spec Name, Active Version, Status (badge), → ("Go to spec →" button).

`Go to spec →` button — Phase 1 fires a "Not wired yet" toast. Phase 7 will navigate to the Quality Specs page filtered to the selected spec.

### Tab 5: Eligibility

Mirrors mockup lines 808–855. Area dropdown ("Die Cast" selected by default), Machine table with 4 columns (Machine, Code, Tonnage, Eligible checkbox).

Phase 1: rows iterate `view.params.value.rows`, Eligible checkbox bidi-bound but only mutates the dummy state. Phase 8 wires real `ItemLocation` data with hierarchy-cascade awareness (Cell-level rows can override Area-level eligibility).

---

## 9. AddItem Modal (`Components/Popups/AddItem`)

Mirrors mockup lines 2629–2715. Modal size 560 px wide. Four sections:

1. **Identity** — PartNumber*, ItemType* (dropdown), UOM* (dropdown), Description*
2. **Weight** — UnitWeight, WeightUOM (dropdown with `—` option)
3. **LOT Configuration** — DefaultSubLotQty, MaxLotSize (labeled `PartsPerBasket` per data model)
4. **ERP Integration** — MacolaPartNumber

Footer: `Cancel`, `Create Item` (primary).

`view.custom` on AddItem:

```yaml
draft:
  PartNumber:       ""
  ItemTypeName:     ""
  UomCode:          "EA"
  Description:      ""
  UnitWeight:       null
  WeightUomCode:    ""
  DefaultSubLotQty: null
  PartsPerBasket:   null
  MacolaPartNumber: ""
itemTypes:          # passed as view.params from parent OR hardcoded dummy in Phase 1
uoms:               # same
```

Phase 1 behavior:
- `Cancel` → `system.perspective.closePopup(id="mpp-add-item")`
- `Create Item` → toast "Not wired yet" + close popup
- Close X icon → same as Cancel (no dirty check in Phase 1; the conventions pack `ConfirmUnsaved` pattern lands in Phase 3 when the Create flow exists)

---

## 10. Sidebar Nav + Page Config

### `page-config/config.json` addition

```json
"/items": {
  "title":    "Item Master",
  "viewPath": "BlueRidge/Views/Parts/ItemMaster"
}
```

### Sidebar addition

The existing sidebar at `Views/Containers/Sidebar/view.json` will get a new entry under a Parts group (creating the group if it doesn't exist). The exact JSON shape follows whatever pattern existing entries use (Plant Hierarchy, Defect Codes, etc.) — implementation plan will inspect the file and follow precedent.

---

## 11. Stylesheet

Phase 1 should not require new CSS classes — the mockup uses utility classes (`.title-row`, `.tree-panel`, `.detail-panel`, `.tab-strip`, `.tab-item`, `.tab-content`, `.data-table`, `.field-row`, `.field`, `.field-label`, `.search-input`, `.select`, `.badge`, `.arrows`, `.arrow-btn`, etc.) that are presumed to already exist in `stylesheet/stylesheet.css` from prior view builds. The implementation plan will spot-check this and add any missing utility classes (using the `psc-` prefix in the CSS file, referenced without the prefix from view.json per the conventions pack).

If specific badge styles (`badge-type`, `badge-published`, `badge-draft`) are missing they'll be added alongside this build.

---

## 12. What "Done" Looks Like for Phase 1

1. `scan.ps1` returns green.
2. Designer opens the project clean — no NPEs, no missing-resource warnings.
3. `/items` page loads in a browser session and renders identically to mockup §"SCREEN: Item Master" with 5G0 Front Cover selected.
4. Clicking any item in the left panel updates the right detail area's PartNumber / Description / ItemType / etc.
5. Editing any form field flips the `● Unsaved changes` indicator in the title bar (validates bidirectional binding works through the embedded tab views).
6. Tab switching shows the correct panel (Container Config / Routes / BOMs / Quality Specs / Eligibility) with corresponding dummy data.
7. `+Add Item` button opens the AddItem modal; Cancel and Create both close it without DB churn.
8. Save / Deprecate / Create Item / New Version / Go to spec buttons fire "Not wired yet" toasts via `BlueRidge.Common.Notify.toast`.
9. Sidebar shows the new Parts → Item Master link and clicking it lands on `/items`.

No green SQL test suite gate — this phase touches no SQL.

---

## 13. Risks + Open Questions

| # | Item | Mitigation |
|---|---|---|
| R1 | Bidirectional binding on Embedded View `props.params.value` may not propagate child mutations back to parent. Pattern is documented in `02_perspective_views.md` but the project hasn't exercised it on a compound object yet. | If smoke test reveals the binding doesn't round-trip, fall back to a per-tab `editDraft` slice owned by the child, with page-scoped `tabFieldChanged` messages back to the parent. Phase 1 still demonstrates the editDraft pattern; coupling is reworked once in the failing mode. |
| R2 | The mockup's `+ Add Item` modal labels MaxLotSize as `Max LOT Size`, while the data model v1.9 says the column is **repurposed as `PartsPerBasket`**. The page details section uses `Parts Per Basket`. | Modal label updated to match data model semantics (`Default Sub-LOT Qty` + `Parts Per Basket`). Captured in Section 9. |
| R3 | The 5-always-mounted-embed pattern means initial page render mounts all 5 tab views' DOM trees. With dummy data this is trivially cheap; with real data (Phase 2+) Routes/BOMs tabs may have larger tables. | Acceptable for now. If Phase 5/6 surface perf issues, switch to dynamic-path single-embed at that time. |
| R4 | The Embedded View component sizing inside flex parents can be finicky (per `06_component_quirks.md`). Tab panels need to fill the available vertical space without overflowing the TabContainer. | Each Embedded View's `position.grow: 1, basis: 0, shrink: 1` and the child view's `root.position.basis: "100%"` is the documented pattern. Implementation plan calls this out explicitly. |

---

## 14. References

- `mockup/index.html` lines 308–860 (Item Master screen)
- `mockup/index.html` lines 2629–2715 (Add Item modal)
- `MPP_MES_DATA_MODEL.md` §2 Parts Schema — `Item`, `Bom`, `BomLine`, `RouteTemplate`, `RouteStep`, `OperationTemplate`, `ItemLocation`, `ContainerConfig`
- `MPP_MES_FDS.md` §3 Master Data Management — FDS-03-001 through FDS-03-021
- `ignition-context-pack/02_perspective_views.md` — Bidirectional binding, Embedded View params, `position.display` for conditional flex visibility
- `ignition-context-pack/07_conventions_and_antipatterns.md` — Save semantics (editDraft + explicit Save), Mode discriminator, Versioned-entity workflow (Phases 5/6), No drag-and-drop (Phases 5/6 arrows), Folder naming
- `ignition-context-pack/06_component_quirks.md` — Embedded View sizing inside flex
- Existing reference impl: `BlueRidge/Views/Location/PlantHierarchy` + `BlueRidge/Components/Popups/LocationTypeEditor` (editor with editDraft + Cancel + dirty indicator)
- Existing reference impl: `BlueRidge/Views/Audit/FailureLog` + `Components/Audit/TopRow` (sub-view grouping precedent under `Components/<Domain>/`)
