# Item Master Phase 4 — Design Spec (ContainerConfig Section)

**Date:** 2026-05-20
**Author:** Claude (Agent A)
**Scope:** Phase 4 of the 8-phase Item Master Configuration Tool — retrofit the ContainerConfig tab to the per-section ownership pattern, wire its own Save + Discard via the existing `Parts.ContainerConfig_Create` / `_Update` procs, add the deferred `TargetWeight` conditional field, AND lay down the parent's section-dirty + switch-gate infrastructure that subsequent phases will reuse.

## 0 — Convention pointer

This phase is the first to be implemented under the per-section ownership convention codified in the `project_mpp_item_master_pattern` memory (2026-05-20 rev). Read that memory first. The headlines:

- Each section (Identity + 5 tabs = 6) owns its own `selected` / `editDraft` locally inside its embedded view.
- Each section's embed receives a single `params.value: itemId` (BIGINT, input-only — NO bidi, NO Object param).
- Each section has its own Save and Discard buttons.
- Sections broadcast `sectionDirtyChanged` page-scoped messages; parent aggregates into `view.custom.sectionDirty`.
- Tab-switch and item-switch are gated by ConfirmUnsaved popup when any section flag is true.

Phase 4 implements this for the ContainerConfig section AND establishes the parent-side gate infrastructure (because it's first to ship under the convention). When Phase 3 (Identity retrofit + AddItem) later lands, it inherits the gate.

## 1 — Goal

End-state for Phase 4:

1. Clicking an item in the left list writes `view.custom.selectedItemId` on the parent; ContainerConfig embed re-fetches on the id change.
2. ContainerConfig embed loads the active config (or empty defaults), keeps `view.custom.selected` + `view.custom.editDraft` LOCALLY, and renders form fields bidi-bound to its OWN `view.custom.editDraft.<field>`.
3. Editing any field flips the embed's local dirty indicator AND fires `sectionDirtyChanged {section: "containerConfig", isDirty: true}` page-scoped.
4. Parent's `view.custom.sectionDirty.containerConfig` updates from the message; a small dot indicator appears on the Container Config tab label.
5. Clicking a different tab OR a different item in the left list while ContainerConfig is dirty opens ConfirmUnsaved (Save / Discard / Cancel). User's choice routes back via `confirmUnsavedResult` page-scoped; parent fires `sectionSaveRequested` or `sectionDiscardRequested` to the embed, then completes the staged switch.
6. The embed's Save button calls `BlueRidge.Parts.ContainerConfig.update()` (if local `editDraft.Id` exists) or `.add()` (if not), surfaces success/error via `Common.Ui.notifyResult`, and on success refreshes its own local state — clearing the dirty flag, which broadcasts `sectionDirtyChanged {isDirty: false}`.
7. `TargetWeight` field renders when `ClosureMethod == "ByWeight"`, with a client-side guard requiring a positive value.

**Out of scope:**
- Identity section retrofit (Phase 3).
- AddItem modal wiring to `Parts.Item_Create` (Phase 3).
- Routes / BOMs / Quality Specs / Eligibility retrofits (Phases 5–8).
- ContainerConfig deprecation from the UI (proc exists; UI hook deferred until customer signs off per OI-02).

## 2 — Architecture

### 2.1 — Layers (unchanged)

```
Section view  (ContainerConfig embed) -> view.custom.{selected, editDraft} (local state)
              -> calls BlueRidge.Parts.ContainerConfig.add / update / getByItem
BlueRidge.Parts.* -> calls BlueRidge.Common.Db.execMutation / execOne
BlueRidge.Common.Db -> the only layer that calls system.db.runNamedQuery
Named Queries -> EXEC Parts.ContainerConfig_Create / _Update / _GetByItem
Stored Procs  -> already exist with full test coverage; no SQL changes in Phase 4
```

### 2.2 — File deltas

**New (named queries):**
- `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/{query.sql, resource.json}`

**Modified:**
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py` — add `add(data)` and `update(data)` public functions.
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json` — full retrofit per §3 below.
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` — add parent-side gate infrastructure per §4 below: new custom props `selectedItemId`, `sectionDirty`, `pendingSwitch`; the existing tabbed area's tab-onChange wires the gate; the existing `itemRowClicked` handler is rewritten to stage/complete via the gate; new message handlers for `sectionDirtyChanged` / `confirmUnsavedResult`; new customMethods `openConfirmUnsaved`, `completeSwitch`, `cancelSwitch`. The old bundled-editDraft and bundled-selected custom props (which were never actually populated for ContainerConfig) are demolished and replaced with the new shape. The existing Save / Deprecate title-bar buttons (currently toasting "Not wired yet — Phase 3") stay as Phase 3 placeholders since they're Identity-scoped.

**Not modified (Phase 4 boundary):**
- The four other tab embedded views (Routes, BOMs, QualitySpecs, Eligibility) keep their Phase 1 shape. Each phase retrofits its own tab when it lands.
- SQL changes — none. Three procs already exist with full test coverage at `sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql` (11 cases).

### 2.3 — ContainerConfig embed structure (post-retrofit)

```
ContainerConfig/view.json
├── custom
│   ├── selected: {Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
│   │              ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
│   ├── editDraft: same shape as selected
│   └── isDirty (computed via expression binding: selected != editDraft)
├── params
│   └── value: 0      (BIGINT itemId, input-only)
├── propConfig
│   ├── params.value: { paramDirection: "input",
│   │                    onChange: load() }      (re-fetch on itemId change)
│   └── custom.isDirty: expression "{view.custom.editDraft} != {view.custom.selected}"
│                       with onChange that fires sectionDirtyChanged
├── root
│   ├── HeaderRow:  PanelHeader "Container Configuration" + Save + Discard buttons
│   ├── FieldRow1:  TraysPerContainer | PartsPerTray | IsSerialized
│   └── FieldRow2:  ClosureMethod | TargetWeight (display-gated) | DunnageCode | CustomerCode
└── scripts.customMethods:
    ├── load()               -- called on params.value change; fetches getByItem and seeds local state
    ├── handleSave()         -- routes add/update, refreshes local state on success
    └── handleDiscard()      -- editDraft = dict(selected)
    scripts.messageHandlers:
    ├── sectionSaveRequested    -- if payload.section == "containerConfig": self.rootContainer.handleSave()
    └── sectionDiscardRequested -- if payload.section == "containerConfig": self.rootContainer.handleDiscard()
```

### 2.4 — Parent view structure (post-Phase-4)

```
ItemMaster/view.json
├── custom
│   ├── selectedItemId: null        (the BIGINT pushed down to all section embeds)
│   ├── sectionDirty: {identity: false, containerConfig: false,
│   │                    routes: false, boms: false,
│   │                    qualitySpecs: false, eligibility: false}
│   ├── pendingSwitch: null         (or {kind: "tab"|"item", to: <target>})
│   ├── activeTab: "containerConfig"
│   ├── items: []                   (left-list binding, unchanged from Phase 2)
│   ├── itemTypes/uoms: ...         (filter options, unchanged from Phase 2)
│   └── (old editDraft, selected, mode props: REMOVED)
├── root.scripts.customMethods:
│   ├── openConfirmUnsaved(sectionKey, sectionTitle)  -- opens ConfirmUnsaved popup with payload
│   ├── completeSwitch()                              -- applies pendingSwitch (writes selectedItemId or activeTab)
│   └── cancelSwitch()                                -- clears pendingSwitch
└── root.scripts.messageHandlers:
    ├── itemRowClicked       -- check sectionDirty; gate via popup or write selectedItemId
    ├── sectionDirtyChanged  -- update sectionDirty[<payload.section>]
    └── confirmUnsavedResult -- branch on payload.action: save → fire sectionSaveRequested then completeSwitch;
                                discard → fire sectionDiscardRequested then completeSwitch;
                                cancel → cancelSwitch
    (the existing tabContainer's onActiveTabChanged gate is wired similarly to itemRowClicked)
```

The five tab embeds receive `params.value` bound to `view.custom.selectedItemId` (a BIGINT). Existing four-tab Phase-1 bindings change from `view.custom.editDraft.meta.Id` to `view.custom.selectedItemId` to match the new naming. No behavioral change for the four-not-retrofitted tabs since they still ignore the param value.

### 2.5 — sectionDirty + tab indicator

Each tab label in the TabContainer gets a small unsaved-indicator dot rendered via a label whose `props.text` binds to:

```
if({view.custom.sectionDirty.containerConfig}, "●", "")
```

(Identical expression for each tab keyed on its section name.) Inline next to the tab text. This is the visual feedback that an unsaved edit exists in a tab the user isn't currently viewing.

Identity (the header block) has its own dirty marker — Phase 3 wires it. Phase 4 ships with `sectionDirty.identity` always false (until Phase 3 lands).

### 2.6 — Switch-gate semantics

**Tab click** (user clicks a different tab in the TabContainer):

```python
# Parent customMethod: handleTabSwitchRequested(targetTab)
currentTab = self.view.custom.activeTab
if currentTab == targetTab:
    return
if self.view.custom.sectionDirty.get(currentTab, False):
    self.view.custom.pendingSwitch = {"kind": "tab", "to": targetTab}
    self.openConfirmUnsaved(currentTab, sectionTitleFor(currentTab))
    # DO NOT change activeTab yet.
else:
    self.view.custom.activeTab = targetTab
```

**Item-row click** (user clicks a different item in the left list):

```python
# Parent message handler: itemRowClicked(payload)
targetId = payload.get("id")
if targetId is None or targetId == self.view.custom.selectedItemId:
    return
anyDirty = any(self.view.custom.sectionDirty.values())
if anyDirty:
    self.view.custom.pendingSwitch = {"kind": "item", "to": targetId}
    firstDirty = next((k for k, v in self.view.custom.sectionDirty.items() if v), None)
    self.openConfirmUnsaved(firstDirty, sectionTitleFor(firstDirty))
    # DO NOT change selectedItemId yet.
else:
    self.view.custom.selectedItemId = targetId
```

**confirmUnsavedResult** (popup → parent):

```python
# Parent message handler: confirmUnsavedResult(payload)
action = payload.get("action")
pending = self.view.custom.pendingSwitch or {}
if not pending:
    return
if action == "cancel":
    self.view.custom.pendingSwitch = None
    return
# Identify which section the popup was raised for
dirtySection = next((k for k, v in self.view.custom.sectionDirty.items() if v), None)
if action == "save":
    system.perspective.sendMessage("sectionSaveRequested", payload={"section": dirtySection}, scope="page")
elif action == "discard":
    system.perspective.sendMessage("sectionDiscardRequested", payload={"section": dirtySection}, scope="page")
# The section runs its handleSave/handleDiscard, fires sectionDirtyChanged {isDirty: false} on completion.
# The completion of the staged switch happens when sectionDirty[dirtySection] flips back to false.
# Implemented via the sectionDirtyChanged handler — see below.
```

**sectionDirtyChanged** (section → parent):

```python
# Parent message handler: sectionDirtyChanged(payload)
section = payload.get("section")
isDirty = bool(payload.get("isDirty"))
nextMap = dict(self.view.custom.sectionDirty)
nextMap[section] = isDirty
self.view.custom.sectionDirty = nextMap

# If a pending switch is waiting AND the dirty section just went clean AND no other sections are dirty: complete the switch
pending = self.view.custom.pendingSwitch
if pending and not any(nextMap.values()):
    self.completeSwitch()
```

`completeSwitch`:

```python
pending = self.view.custom.pendingSwitch or {}
kind    = pending.get("kind")
target  = pending.get("to")
if kind == "tab":
    self.view.custom.activeTab = target
elif kind == "item":
    self.view.custom.selectedItemId = target
self.view.custom.pendingSwitch = None
```

**Important edge case:** if Save fails (proc returns Status=0, e.g. validation rejected), the section's dirty flag stays true → the staged switch never fires → user stays on the current section to fix the error. This is the intended behavior.

### 2.7 — ContainerConfig data shape

Identical to Phase 1 dummy data shape plus `Id` for the active row reference:

```python
{
    "Id":                <int|None>,        # None == create path, int == update path
    "ItemId":            <int>,             # always the currently-selected item's Id
    "TraysPerContainer": <int|None>,
    "PartsPerTray":      <int|None>,
    "IsSerialized":      <bool>,            # defaults to False
    "ClosureMethod":     <str|None>,        # "ByCount" | "ByWeight" | "ByVision" | None
    "TargetWeight":      <decimal|None>,    # required iff ClosureMethod == "ByWeight"
    "DunnageCode":       <str|None>,
    "CustomerCode":      <str|None>,
}
```

`getByItem(itemId)` returns `None` when no active config → embed seeds the dict with `Id: None`, `ItemId: itemId`, `IsSerialized: False`, others `None`. Save dispatches to `add()`.

### 2.8 — TargetWeight conditional display

New flex container `FieldTargetWeight` inserted between `FieldClosureMethod` and `FieldDunnageCode` in `FieldRow2`. The container's `position.display` binds:

```
{view.custom.editDraft.ClosureMethod} = "ByWeight"
```

Non-tabular layout, so `position.display` (collapses the slot) is correct per `feedback_ignition_meta_visible_in_tables`.

### 2.9 — Save handler in the embed

```python
# In ContainerConfig embed's customMethod handleSave
draft = self.view.custom.editDraft or {}
itemId = self.view.params.value
if not itemId:
    BlueRidge.Common.Notify.toast(
        "No item selected",
        "Select an item before saving container configuration.",
        "warning")
    return

trays = draft.get("TraysPerContainer")
partsPerTray = draft.get("PartsPerTray")
if trays is None or trays <= 0:
    BlueRidge.Common.Notify.toast("Trays per Container required",
        "Enter a positive number of trays per container.", "warning")
    return
if partsPerTray is None or partsPerTray <= 0:
    BlueRidge.Common.Notify.toast("Parts per Tray required",
        "Enter a positive number of parts per tray.", "warning")
    return
if draft.get("ClosureMethod") == "ByWeight":
    tw = draft.get("TargetWeight")
    if tw is None or tw <= 0:
        BlueRidge.Common.Notify.toast("Target Weight required",
            "ByWeight closure requires a positive target weight.", "warning")
        return

payload = dict(draft)
payload["ItemId"] = itemId
if payload.get("Id"):
    result       = BlueRidge.Parts.ContainerConfig.update(payload)
    successTitle = "Container config updated"
else:
    result       = BlueRidge.Parts.ContainerConfig.add(payload)
    successTitle = "Container config saved"

BlueRidge.Common.Ui.notifyResult(result, successTitle)

if result and result.get("Status"):
    # Re-fetch to pick up server timestamps + NewId on Create.
    self.rootContainer.load()
    # load() also clears local dirty via selected reset → fires sectionDirtyChanged {isDirty: false}
```

### 2.10 — Load handler in the embed

Called from `params.value` onChange and from `handleSave` after a successful mutation:

```python
itemId = self.view.params.value
if not itemId:
    empty = {
        "Id": None, "ItemId": None,
        "TraysPerContainer": None, "PartsPerTray": None,
        "IsSerialized": False,
        "ClosureMethod": None, "TargetWeight": None,
        "DunnageCode": None, "CustomerCode": None,
    }
    self.view.custom.selected  = dict(empty)
    self.view.custom.editDraft = dict(empty)
    return

row = BlueRidge.Parts.ContainerConfig.getByItem(itemId) or {}
loaded = {
    "Id":                row.get("Id"),
    "ItemId":            itemId,
    "TraysPerContainer": row.get("TraysPerContainer"),
    "PartsPerTray":      row.get("PartsPerTray"),
    "IsSerialized":      bool(row.get("IsSerialized", False)),
    "ClosureMethod":     row.get("ClosureMethod"),
    "TargetWeight":      row.get("TargetWeight"),
    "DunnageCode":       row.get("DunnageCode"),
    "CustomerCode":      row.get("CustomerCode"),
}
self.view.custom.selected  = dict(loaded)
self.view.custom.editDraft = dict(loaded)
```

### 2.11 — Dirty broadcast

The embed's `custom.isDirty` is an expression-bound boolean. Its onChange handler fires the page-scoped message:

```python
# onChange of view.custom.isDirty
system.perspective.sendMessage(
    "sectionDirtyChanged",
    payload={"section": "containerConfig", "isDirty": bool(currentValue.value)},
    scope="page",
)
```

(The `bool(currentValue.value)` unwraps the QualifiedValue Ignition hands to onChange handlers.)

### 2.12 — Discard handler

```python
# In ContainerConfig embed's customMethod handleDiscard
self.view.custom.editDraft = dict(self.view.custom.selected)
# isDirty flips to false via the expression binding → fires sectionDirtyChanged {isDirty: false}
```

### 2.13 — Entity script additions

`BlueRidge.Parts.ContainerConfig.code.py` gains two functions, following the DefectCode CRUD shape:

```python
def add(data):
    """Create a new active ContainerConfig for an Item.

    data: {ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
    Returns {Status, Message, NewId}.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Create",
        {
            "itemId":            data.get("ItemId"),
            "traysPerContainer": data.get("TraysPerContainer"),
            "partsPerTray":      data.get("PartsPerTray"),
            "isSerialized":      bool(data.get("IsSerialized", False)),
            "dunnageCode":       data.get("DunnageCode"),
            "customerCode":      data.get("CustomerCode"),
            "closureMethod":     data.get("ClosureMethod"),
            "targetWeight":      data.get("TargetWeight"),
            "appUserId":         BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update an existing active ContainerConfig in place. ItemId is
    immutable per the proc.

    data: {Id, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
    Returns {Status, Message}.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Update",
        {
            "id":                data.get("Id"),
            "traysPerContainer": data.get("TraysPerContainer"),
            "partsPerTray":      data.get("PartsPerTray"),
            "isSerialized":      bool(data.get("IsSerialized", False)),
            "dunnageCode":       data.get("DunnageCode"),
            "customerCode":      data.get("CustomerCode"),
            "closureMethod":     data.get("ClosureMethod"),
            "targetWeight":      data.get("TargetWeight"),
            "appUserId":         BlueRidge.Common.Util._currentAppUserId(),
        },
    )
```

## 3 — Named Query specifics

Two new NQs. Both:

- `scope: "DG"`, `version: 2`, `database: "MPP"`.
- `type: "Query"` — terminating `SELECT @Status, @Message [, @NewId]` consumed as a result set.
- `cacheEnabled: false`.
- Parameter identifiers in camelCase.
- `sqlType` enum (Designer's): `Int8 = 3` (BIGINT), `Int4 = 4` (INT), `Boolean = 6` (BIT), `String = 7` (NVARCHAR), `Decimal = 8` (DECIMAL). If any of these don't match the Designer-canonical save output for an existing NQ, defer to the existing NQ as authoritative.

### 3.1 — `parts/ContainerConfig_Create`

```sql
EXEC Parts.ContainerConfig_Create
    @ItemId            = :itemId,
    @TraysPerContainer = :traysPerContainer,
    @PartsPerTray      = :partsPerTray,
    @IsSerialized      = :isSerialized,
    @DunnageCode       = :dunnageCode,
    @CustomerCode      = :customerCode,
    @ClosureMethod     = :closureMethod,
    @TargetWeight      = :targetWeight,
    @AppUserId         = :appUserId
```

### 3.2 — `parts/ContainerConfig_Update`

```sql
EXEC Parts.ContainerConfig_Update
    @Id                = :id,
    @TraysPerContainer = :traysPerContainer,
    @PartsPerTray      = :partsPerTray,
    @IsSerialized      = :isSerialized,
    @DunnageCode       = :dunnageCode,
    @CustomerCode      = :customerCode,
    @ClosureMethod     = :closureMethod,
    @TargetWeight      = :targetWeight,
    @AppUserId         = :appUserId
```

Reference resource.json shapes: `quality/DefectCode_Create/resource.json` (Create proc with NewId), `quality/DefectCode_Update/resource.json` (Update proc, no NewId).

## 4 — Conventions checklist

- **NQ resource.json** v2 schema, sqlType enum (3/4/6/7/8), Designer-canonical field order.
- **No `system.db.*` in entity scripts.** Every DB call goes through `BlueRidge.Common.Db.execMutation`.
- **No OUTPUT params in any proc.**
- **`_u()` deep-unwrap** at every public-handler entry that receives a view-side value.
- **`BlueRidge.Common.Util.log(...)`** at entry of every public function.
- **camelCase NQ params**; PascalCase proc params.
- **AppUserId attribution** sourced from `_currentAppUserId()` inside the entity script — never passed from the view.
- **Page-scoped messages** for all section ↔ parent communication. `scope="page"`, `pageScope: true` on handlers per [[feedback_ignition_message_scope]].
- **`params` list MUST NOT include `"self"`** per [[feedback_ignition_view_customMethods_scope]] — Ignition auto-prepends it.

## 5 — Out of scope (deferred)

| Item | Lands in |
|---|---|
| Identity section retrofit (Save/Discard wiring + sectionDirty integration for the header block) | Phase 3 |
| AddItem modal → `Parts.Item_Create` | Phase 3 |
| `PartsPerBasket` Identity-field cleanup (not a real column) | Phase 3 |
| Routes section retrofit | Phase 5 |
| BOMs section retrofit | Phase 6 |
| Quality Specs section retrofit | Phase 7 |
| Eligibility section retrofit | Phase 8 |
| ContainerConfig deprecation from UI (proc exists) | Future (post OI-02 resolution) |

## 6 — Risks and verification

| Risk | Mitigation |
|---|---|
| Reassigning `view.custom.editDraft` doesn't refire the field bindings on the embed | Field bindings are bidirectional `view.custom.editDraft.<field>`, not on the dict itself; per-field reassignment fires per-field bindings. Reassigning the whole dict on a clone is the project-proven pattern in DefectCodeEditor / DowntimeCodeEditor. |
| `sectionDirty` flag race when `sectionDirtyChanged` fires before parent's pending switch is staged | Parent stages `pendingSwitch` BEFORE opening the popup. Sequence is deterministic. The completion check in `sectionDirtyChanged` only triggers if a pendingSwitch exists. |
| `isDirty` expression evaluates true on cold open due to default-value drift between `selected` and `editDraft` | `load()` writes both `selected` and `editDraft` from the same `loaded` dict via independent `dict(...)` clones. Deep-equal on first paint. |
| Dropdown component fires false `isDirty` on cold open due to the IsSerialized value default | `IsSerialized: False` matches the bool default in `loaded`. If Designer round-trips the dropdown's default to a different type (e.g., int 0), a one-time normalize in `load()` covers it. Worth verifying in smoke step 2. |
| User selects a different item from the left list while ContainerConfig save is in flight | UI is single-threaded in the Perspective session. Save is synchronous from `system.db.runNamedQuery`. The item-click handler runs after the save completes. Not a concern in this scope. |

## 7 — Designer smoke checklist (Jacques, post-merge)

1. **Cold open** Item Master view. **Pass:** all tab labels render without dirty dots; Container Config tab shows blank fields; no toasts.
2. **Click an Item row** that already has a ContainerConfig. **Pass:** Container Config tab populates from DB; Container Config tab label has no dirty dot; `view.custom.sectionDirty.containerConfig` in the property browser reads `false`.
3. **Change ClosureMethod** from `ByCount` to `ByWeight`. **Pass:** TargetWeight field appears; Container Config tab label shows the `●` dirty dot; `view.custom.sectionDirty.containerConfig` reads `true`.
4. **Try to click the Routes tab.** **Pass:** ConfirmUnsaved popup opens with message referencing Container Config; activeTab stays on containerConfig.
5. **Click Cancel in the popup.** **Pass:** popup closes; activeTab still containerConfig; dirty dot still showing.
6. **Click the Routes tab again, popup opens, click Discard.** **Pass:** ContainerConfig fields revert; dirty dot clears; popup closes; Routes tab becomes active.
7. **Back to Container Config tab, change ClosureMethod to ByWeight again, leave TargetWeight blank, click Save.** **Pass:** warning toast "Target Weight required"; no DB write; dirty dot still showing.
8. **Fill TargetWeight=12.50, click Save.** **Pass:** success toast "Container config updated"; dirty dot clears; values persist visually.
9. **Click a different Item in the left list (one with no ContainerConfig).** **Pass:** Container Config tab shows blank fields; previously edited item's values do NOT carry over; dirty dot stays clear.
10. **Fill TraysPerContainer=4, PartsPerTray=12, IsSerialized=Yes, ClosureMethod=ByCount, click Save.** **Pass:** success toast "Container config saved"; the embed's `view.custom.editDraft.Id` (in property browser) is now a real BIGINT; dirty dot stays clear; clicking back to the previous item still shows its updated config (no cross-contamination).
11. **With a dirty ContainerConfig edit, click a different Item row.** **Pass:** ConfirmUnsaved popup opens. Confirm Save path completes the item switch after a successful save. Confirm Discard path completes the item switch after reverting. Confirm Cancel keeps current item + dirty edit.

Steps 1–11 PASS → Phase 4 complete. Any FAIL → halt and triage; the architectural choices in §2.6 are load-bearing.

## 8 — Open questions (none blocking)

OI-02 (ClosureMethod enum lock + backend validation on TargetWeight presence) is a customer-validation item, not a Phase 4 design gate.

---

**Approval:** Self-approved under auto mode. Subject to Jacques's review of the spec post-write.
