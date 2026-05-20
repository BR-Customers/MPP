# Item Master Phase 4 — Design Spec (ContainerConfig Save)

**Date:** 2026-05-20
**Author:** Claude (Agent A)
**Scope:** Phase 4 of the 8-phase Item Master Configuration Tool — wire Save for the ContainerConfig slice using the existing `Parts.ContainerConfig_Create` / `Parts.ContainerConfig_Update` procs, repair the parent↔child binding contract that Phase 2 left inconsistent with the Phase 1/2 design intent, and add the `TargetWeight` conditional display deferred from Phase 1.

## 1 — Goal

End-state for Phase 4:

1. Selecting an Item loads its ContainerConfig (or empty defaults) into `view.custom.editDraft.containerConfig` on the parent.
2. The ContainerConfig embedded view's form fields bidirectionally edit `view.custom.editDraft.containerConfig` via `props.params.value` (no separate child-side DB query, no separate child-side state).
3. Editing any field flips the parent title bar's `● Unsaved changes` indicator.
4. Pressing the parent's **Save** button calls `BlueRidge.Parts.ContainerConfig.update()` (when `editDraft.containerConfig.Id` exists) or `.add()` (when it doesn't), surfaces success/error via `Common.Ui.notifyResult`, and on success refreshes `selected.containerConfig` + `editDraft.containerConfig` from the DB so the dirty indicator clears and a freshly-created config picks up its server-assigned `Id`.
5. `TargetWeight` field is rendered with `position.display` bound to `ClosureMethod == 'ByWeight'`; client-side guard requires a positive value when shown.

**Out of scope:** Item meta save / Item create / Item deprecate (Phase 3). Routes / BOMs / Quality Specs / Eligibility slices (Phases 5–8). ContainerConfig deprecation from the UI — the proc exists but no UI hook lands until customer validation per OI-02.

## 2 — The wiring drift discovered

The Phase 2 spec §3.5 and the Phase 1 spec §8 describe a bidirectional Object-param pattern:

- Parent's `EmbedContainerConfig.props.params.value` ← bidi → `view.custom.editDraft.containerConfig` (an object)
- Child's `params.value` declared `paramDirection: input`, default `{}` (an object)
- Child form fields bidi-bind to `view.params.value.<field>`

The actual Phase 2 code shipped a different shape:

- Parent's `EmbedContainerConfig.props.params.value` ← `view.custom.editDraft.meta.Id` (a BIGINT, not an object; not bidi)
- Child's `params.value` declared `paramDirection: input`, default `0`
- Child has its own `view.custom.data` bound via `runScript("...ContainerConfig.getByItem", 0, {view.params.value})` — its own DB query
- Child form fields bidi-bind to `view.custom.data.<field>` (the child's own state, not the parent's)

Consequence: the parent's `editDraft.containerConfig` is permanently `{}`. The child's form mutations write to `custom.data` only and never surface up. The dirty indicator never lights for ContainerConfig edits. Save has no draft to persist.

Phase 4's first task is to bring the wiring back to the spec's intent. This is also a forcing function on the R1 (bidirectional embed) risk — Phase 2's R1 smoke was never run because the wiring was never built. Phase 4 IS the R1 test.

## 3 — Architecture

### 3.1 — Layers (unchanged)

```
View bindings        -> view.custom.editDraft.containerConfig (parent state)
                     -> view.params.value (child input, bidi)
view.scripts         -> calls BlueRidge.Parts.ContainerConfig.add / update / getByItem
BlueRidge.Parts.*    -> calls BlueRidge.Common.Db.execMutation / execOne
BlueRidge.Common.Db  -> the only layer that calls system.db.runNamedQuery
Named Queries        -> EXEC Parts.ContainerConfig_Create / _Update / _GetByItem
Stored Procs         -> already exist; no SQL changes in Phase 4
```

### 3.2 — File deltas

**New:**

- `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/{query.sql, resource.json}`

**Modified:**

- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py` — add `add(data)` and `update(data)` public functions following the DefectCode CRUD shape.
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json` — remove `custom.data` + the `getByItem` runScript binding; change `params.value` default from `0` (int) to `{}` (dict); rebind every form field's path from `view.custom.data.<field>` → `view.params.value.<field>`; add a new `TargetWeight` text-field after `ClosureMethod` with `position.display` bound to `{view.params.value.ClosureMethod} = 'ByWeight'`.
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` — change EmbedContainerConfig's `props.params.value` binding from `view.custom.editDraft.meta.Id` → `view.custom.editDraft.containerConfig` with `bidirectional: true`; extend the `itemRowClicked` message handler to fetch ContainerConfig and write both `selected.containerConfig` and `editDraft.containerConfig`; replace the BtnSave placeholder script with a Phase 4 ContainerConfig-aware handler routed through a new view-level `handleSave` customMethod.

**Not modified (Phase 4 boundary):**

- The other four tab embedded views (`Routes`, `Boms`, `QualitySpecs`, `Eligibility`) keep their Phase 1 shape — they continue to receive `view.custom.editDraft.meta.Id` as their `params.value`. Phases 5–8 will rewire them to their respective bidi slices.
- No SQL changes. The three procs already exist with full test coverage in `sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql`.
- The dirty indicator binding stays as-is. Its `editDraft != selected` comparison naturally extends to `containerConfig` once both sides are populated symmetrically.

### 3.3 — Data shapes

**ContainerConfig draft (lives at `view.custom.editDraft.containerConfig` and `view.params.value`):**

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

When `getByItem(itemId)` returns `None` (no active config exists), the parent seeds the empty defaults shape with `Id: None`, `ItemId: itemId`, `IsSerialized: False`, and all other fields `None`. The child renders blank fields. Save will route to `add()`.

When `getByItem(itemId)` returns a row, the parent seeds the dict with the row's values verbatim. Save will route to `update()`.

### 3.4 — Parent itemRowClicked (extended)

Current Phase 2 handler (per the view's message handlers) writes only `meta` and `mode`. Extension:

```python
clickedId = payload.get("id") if payload else None
if clickedId is None:
    return
itemMeta = BlueRidge.Parts.Item.getOne(clickedId)
if itemMeta is None:
    BlueRidge.Common.Notify.toast(
        "Item not found",
        "Item id " + str(clickedId) + " no longer exists.",
        "warning")
    return
ccRow = BlueRidge.Parts.ContainerConfig.getByItem(clickedId) or {}
cc = {
    "Id":                ccRow.get("Id"),
    "ItemId":            clickedId,
    "TraysPerContainer": ccRow.get("TraysPerContainer"),
    "PartsPerTray":      ccRow.get("PartsPerTray"),
    "IsSerialized":      bool(ccRow.get("IsSerialized", False)),
    "ClosureMethod":     ccRow.get("ClosureMethod"),
    "TargetWeight":      ccRow.get("TargetWeight"),
    "DunnageCode":       ccRow.get("DunnageCode"),
    "CustomerCode":      ccRow.get("CustomerCode"),
}
self.view.custom.selected  = {"meta": dict(itemMeta),  "containerConfig": dict(cc)}
self.view.custom.editDraft = {"meta": dict(itemMeta),  "containerConfig": dict(cc)}
self.view.custom.mode      = "update"
```

Two independent `dict(...)` clones keep `editDraft` and `selected` distinct objects — the dirty indicator's deep-compare relies on this.

### 3.5 — Embedded view rewiring

Three field-path changes (and one new field) inside `ContainerConfig/view.json`:

| Field | Old binding path | New binding path |
|---|---|---|
| `InputTraysPerContainer.props.text` | `view.custom.data.TraysPerContainer` | `view.params.value.TraysPerContainer` |
| `InputPartsPerTray.props.text` | `view.custom.data.PartsPerTray` | `view.params.value.PartsPerTray` |
| `DropdownIsSerialized.props.value` | `view.custom.data.IsSerialized` | `view.params.value.IsSerialized` |
| `DropdownClosureMethod.props.value` | `view.custom.data.ClosureMethod` | `view.params.value.ClosureMethod` |
| `InputDunnageCode.props.text` | `view.custom.data.DunnageCode` | `view.params.value.DunnageCode` |
| `InputCustomerCode.props.text` | `view.custom.data.CustomerCode` | `view.params.value.CustomerCode` |
| `InputTargetWeight.props.text` (NEW) | — | `view.params.value.TargetWeight` |

All bindings stay `bidirectional: true`. The `view.custom.data` property and its expression binding are removed entirely.

The new `TargetWeight` field is inserted between `ClosureMethod` and `DunnageCode` in `FieldRow2`. Its container's `position.display` binds:

```
{view.params.value.ClosureMethod} = "ByWeight"
```

This is a flex-row slot (non-tabular), so `position.display` is the correct knob per [[ignition-meta-visible-in-tables]] — collapsing the slot when ByWeight is not selected.

### 3.6 — Parent EmbedContainerConfig rewiring

Current (Phase 2):

```json
"propConfig": {
  "props.params.value": {
    "binding": {
      "type": "property",
      "config": { "path": "view.custom.editDraft.meta.Id" }
    }
  }
}
```

Phase 4:

```json
"propConfig": {
  "props.params.value": {
    "binding": {
      "type": "property",
      "config": {
        "bidirectional": true,
        "path": "view.custom.editDraft.containerConfig"
      }
    }
  }
}
```

The other four tabs (Routes, Boms, QualitySpecs, Eligibility) keep their existing `editDraft.meta.Id` non-bidi bindings unchanged.

### 3.7 — Save button wiring

The TitleBar `BtnSave` currently does `BlueRidge.Common.Notify.toast(...)` ("Not wired yet"). Phase 4 replaces its `onActionPerformed` with a one-liner that calls a parent-view customMethod:

```python
self.view.rootContainer.handleSave()
```

The customMethod (added on `root.scripts.customMethods`) does:

```python
def handleSave(self):
    draft   = self.view.custom.editDraft or {}
    meta    = draft.get("meta") or {}
    cc      = dict(draft.get("containerConfig") or {})
    itemId  = meta.get("Id")

    # Phase 4 only saves ContainerConfig. Item meta save is Phase 3.
    if not itemId:
        BlueRidge.Common.Notify.toast(
            "No item selected",
            "Select an item before saving container configuration.",
            "warning")
        return

    # Client-side guards (proc enforces too, but UI toast is friendlier).
    trays = cc.get("TraysPerContainer")
    partsPerTray = cc.get("PartsPerTray")
    if trays is None or trays <= 0:
        BlueRidge.Common.Notify.toast(
            "Trays per Container required",
            "Enter a positive number of trays per container.",
            "warning")
        return
    if partsPerTray is None or partsPerTray <= 0:
        BlueRidge.Common.Notify.toast(
            "Parts per Tray required",
            "Enter a positive number of parts per tray.",
            "warning")
        return
    if cc.get("ClosureMethod") == "ByWeight":
        tw = cc.get("TargetWeight")
        if tw is None or tw <= 0:
            BlueRidge.Common.Notify.toast(
                "Target Weight required",
                "ByWeight closure requires a positive target weight.",
                "warning")
            return

    cc["ItemId"] = itemId  # Required for add; ignored by update proc.
    if cc.get("Id"):
        result       = BlueRidge.Parts.ContainerConfig.update(cc)
        successTitle = "Container config updated"
    else:
        result       = BlueRidge.Parts.ContainerConfig.add(cc)
        successTitle = "Container config saved"

    BlueRidge.Common.Ui.notifyResult(result, successTitle)

    if result and result.get("Status"):
        # Re-fetch to pick up server timestamps + NewId on Create.
        refreshed = BlueRidge.Parts.ContainerConfig.getByItem(itemId) or {}
        newCc = {
            "Id":                refreshed.get("Id"),
            "ItemId":            itemId,
            "TraysPerContainer": refreshed.get("TraysPerContainer"),
            "PartsPerTray":      refreshed.get("PartsPerTray"),
            "IsSerialized":      bool(refreshed.get("IsSerialized", False)),
            "ClosureMethod":     refreshed.get("ClosureMethod"),
            "TargetWeight":      refreshed.get("TargetWeight"),
            "DunnageCode":       refreshed.get("DunnageCode"),
            "CustomerCode":      refreshed.get("CustomerCode"),
        }
        # Replace BOTH the editDraft and selected containerConfig slots
        # via parent-dict reassignment so the bidi binding re-fires on
        # the child. Reassigning a nested key alone may not signal change.
        nextDraft = dict(self.view.custom.editDraft)
        nextDraft["containerConfig"] = dict(newCc)
        self.view.custom.editDraft = nextDraft
        nextSelected = dict(self.view.custom.selected)
        nextSelected["containerConfig"] = dict(newCc)
        self.view.custom.selected = nextSelected
```

The save handler does NOT touch the items list — ContainerConfig is per-item, not a list-level entity. There's no equivalent of DefectCodes' page-scoped refresh message.

### 3.8 — Entity script additions

`BlueRidge.Parts.ContainerConfig.code.py` gains two functions, following the DefectCode CRUD shape:

```python
def add(data):
    """Create a new active ContainerConfig for an Item.
       data: {ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
              ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
       Returns {Status, Message, NewId}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Create",
        {
            "itemId":             data.get("ItemId"),
            "traysPerContainer":  data.get("TraysPerContainer"),
            "partsPerTray":       data.get("PartsPerTray"),
            "isSerialized":       bool(data.get("IsSerialized", False)),
            "dunnageCode":        data.get("DunnageCode"),
            "customerCode":       data.get("CustomerCode"),
            "closureMethod":      data.get("ClosureMethod"),
            "targetWeight":       data.get("TargetWeight"),
            "appUserId":          BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update an existing active ContainerConfig in place. ItemId is
       immutable per the proc; to re-associate, deprecate + create.
       data: {Id, TraysPerContainer, PartsPerTray, IsSerialized,
              ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
       Returns {Status, Message}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Update",
        {
            "id":                 data.get("Id"),
            "traysPerContainer":  data.get("TraysPerContainer"),
            "partsPerTray":       data.get("PartsPerTray"),
            "isSerialized":       bool(data.get("IsSerialized", False)),
            "dunnageCode":        data.get("DunnageCode"),
            "customerCode":       data.get("CustomerCode"),
            "closureMethod":      data.get("ClosureMethod"),
            "targetWeight":       data.get("TargetWeight"),
            "appUserId":          BlueRidge.Common.Util._currentAppUserId(),
        },
    )
```

The `_u(data)` deep-unwrap is essential because `data` arrives from the parent view as a Python dict that may have round-tripped through Perspective's property layer (potentially Java-wrapped values inside).

`deprecate(id)` is not added in Phase 4 — no UI hook lands until customer signs off on the deprecation workflow.

## 4 — Named Query specifics

Two new NQs. Both:

- `scope: "DG"` (Designer / Gateway), `version: 2`, `database: "MPP"`.
- `type: "Query"` (not `UpdateQuery`) — the proc's terminating `SELECT @Status, @Message [, @NewId]` is consumed as a result set per project convention.
- `cacheEnabled: false`.
- Parameter identifiers in camelCase (per pack convention).
- `sqlType`: `Int8 = 3` for BIGINT, `String = 7` for NVARCHAR, `Boolean = 6` for BIT, `Decimal = 8` for DECIMAL.
- `lastModification.actor: "claude"`, `lastModificationSignature: ""` (forces Designer to treat as fresh).

### 4.1 — `parts/ContainerConfig_Create`

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

### 4.2 — `parts/ContainerConfig_Update`

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

Reference resource.json shape: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Create/resource.json` is the closest analog (Create proc with same return shape: `Status, Message, NewId`).

## 5 — Conventions checklist

- **NQ resource.json** v2 schema, `sqlType` enum (3 / 6 / 7 / 8), Designer-canonical field order. Reference: `quality/DefectCode_Create/resource.json` (for Create) and `quality/DefectCode_Update/resource.json` (for Update).
- **No `system.db.*` in entity scripts.** Every DB call goes through `BlueRidge.Common.Db.execMutation`.
- **No OUTPUT params in any proc** — Phase 4 uses existing procs that already follow this rule. Result is consumed as a single result set.
- **Mutation funcs return result dict raw** — `execMutation` already deep-unwraps. Callers (view scripts) inspect `result.get("Status")` truthy.
- **`_u()` deep-unwrap** at every public-handler entry that receives a view-side value (incl. the `data` arg to `add` / `update`).
- **`BlueRidge.Common.Util.log(...)`** at entry of every public function.
- **camelCase NQ params**; PascalCase proc params (matches existing pattern).
- **AppUserId attribution** sourced from `BlueRidge.Common.Util._currentAppUserId()` inside the entity script — never passed from the view.

## 6 — Out of scope (deferred)

| Item | Lands in |
|---|---|
| Item Create / Update / Deprecate procs called from UI | Phase 3 |
| ContainerConfig deprecation from UI (proc exists) | Future (post OI-02 / OI-24 resolution) |
| Routes tab live data | Phase 5 (designed) |
| BOMs tab live data | Phase 6 (designed) |
| Quality Specs tab live data | Phase 7 |
| Eligibility tab live data | Phase 8 |
| `PartsPerBasket` field cleanup on the parent Identity row (not a real column) | Phase 3 |
| Rewiring the other four tab embedded views' `params.value` to their respective bidi slices | Phases 5–8 (each phase rewires its own tab) |

## 7 — Risks and verification

| Risk | Mitigation |
|---|---|
| **R1** — bidi `props.params.value` ↔ parent `view.custom.editDraft.containerConfig` doesn't round-trip across the embed boundary in Ignition 8.3 | The Phase 4 Designer smoke (§8) is the R1 test. If it fails after Task 1's wiring change, halt the plan, follow the fallback in §7.1, and revisit. |
| Reassigning a nested key on `editDraft` doesn't propagate to the bidi binding | Save handler reassigns the parent dict via `dict(editDraft)` clone + key set + assign back. Empirically the most reliable pattern in Perspective. |
| ClosureMethod==ByWeight + TargetWeight=NULL slips past the client guard | Proc validation enforces nothing on this combination today (data model allows NULL); Phase 4 adds the client guard as best-effort UX. Backend hardening is OI-02 territory. |
| User clicks Save while no item is selected | Guard at the top of `handleSave` toasts a warning and returns. The Save button itself is not disabled — keeping the toast path uniform for now. |
| Designer caches the parent view and clobbers file edits | Jacques keeps Designer closed during file edits per the close-first protocol (`feedback_ignition_view_edit_boundary.md`). |

### 7.1 — R1 fallback (only invoked if Designer smoke fails)

If the smoke's dirty-indicator step fails after Task 1's wiring change is in, the fallback is the same shape Phase 2's spec described:

| Layer | Behavior |
|---|---|
| Parent | `props.params.value` becomes **input-only** (drop `bidirectional: true`). Whenever the parent writes `editDraft.containerConfig`, it also fires a `containerConfigPushed` page-scoped message with the dict as payload. Receives `containerConfigChanged` page-scoped messages back from the child and writes payload into `editDraft.containerConfig` (parent-dict reassign). |
| Child | Holds its own `view.custom.editDraft` initialized from `view.params.value` (on view-open AND on `containerConfigPushed` message). Form fields bidi-bind to `view.custom.editDraft.<field>`. Any field change fires `containerConfigChanged` with the full slice as payload. |

This path adds 2 page-scoped messages + a child-side custom prop + a child-side initialization handler. Plan a follow-up task block to implement if R1 fails.

## 8 — Designer smoke checklist (Jacques, post-merge)

After branch lands on main and gateway scans:

1. **Cold open** Item Master view. **Pass:** title bar empty, all tabs blank, dirty indicator clear.
2. **Click an Item row** that already has a ContainerConfig in the DB (the seed includes Honda 5G0 family). **Pass:** Identity header populates AND the Container Config tab fields show the DB values (TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, etc.). Dirty indicator stays clear (selected == editDraft).
3. **Open Designer property browser** on the parent view → expand `view.custom.editDraft.containerConfig`. **Pass:** keys match the DB row.
4. **Change ClosureMethod dropdown** from `ByCount` to `ByWeight`. **R1 pass:** title bar shows `● Unsaved changes` AND `view.custom.editDraft.containerConfig.ClosureMethod` reads `ByWeight` in the property browser AND the `TargetWeight` field appears below ClosureMethod. **R1 fail:** dirty indicator stays blank OR parent's editDraft.containerConfig.ClosureMethod is unchanged → halt, follow §7.1.
5. **Type a TargetWeight value** (e.g. `12.50`). **Pass:** field accepts decimal input.
6. **Click Save** with ClosureMethod=ByWeight + TargetWeight blank. **Pass:** warning toast "Target Weight required"; no DB write; dirty indicator still shown.
7. **Restore TargetWeight=12.50, click Save.** **Pass:** success toast "Container config updated"; dirty indicator clears; reopen the property browser — `editDraft.containerConfig.Id` is unchanged (Update path); UpdatedAt timestamp refreshed (visible via a DB query).
8. **Pick an Item with no existing ContainerConfig.** **Pass:** Container Config tab shows blank fields, no `Id` in `editDraft.containerConfig`.
9. **Fill TraysPerContainer=4, PartsPerTray=12, IsSerialized=Yes, ClosureMethod=ByCount, save.** **Pass:** success toast "Container config saved"; reopen property browser — `editDraft.containerConfig.Id` is now a real BIGINT; dirty indicator clears; re-click the same item — fields persist (no refresh needed since editDraft was updated in-place).
10. **Try to save with TraysPerContainer=0.** **Pass:** warning toast "Trays per Container required".

Steps 1–10 PASS → Phase 4 complete. Step 4 FAIL → halt, R1 fallback (§7.1) becomes its own plan.

## 9 — Open questions (none blocking)

The single open question (OI-02: full enum lock for ClosureMethod values + backend validation on TargetWeight presence) is a customer-validation item, not a Phase 4 design gate. The proc accepts NVARCHAR(20) for ClosureMethod and NULL for TargetWeight today; the UI is honest about those constraints via client guards.

---

**Approval:** Self-approved under auto mode. Subject to Jacques's review of the spec post-write.
