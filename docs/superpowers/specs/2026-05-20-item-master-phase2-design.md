# Item Master Phase 2 — Design Spec

**Date:** 2026-05-20
**Author:** Claude (Agent B)
**Scope:** Phase 2 of the 8-phase Item Master Configuration Tool — DB read paths for the items list + item details, plus a controlled smoke test of the R1 architectural risk inherited from Phase 1.

## 1 — Goal

Replace the hardcoded `view.custom.items` and `view.custom.selected`/`view.custom.editDraft` seeds in `BlueRidge/Views/Parts/ItemMaster/view.json` with live SQL-backed reads. End-state for Phase 2: clicking any Item in the left panel populates the Identity header + the ContainerConfig tab from the database; editing a ContainerConfig field flips the parent's `● Unsaved changes` indicator. The other four tabs (Routes, BOMs, Quality Specs, Eligibility) keep an empty/default slice until their own phases land.

Phase 2 is read-only. Item save / deprecate / create is Phase 3. ContainerConfig save is Phase 4.

## 2 — R1 Smoke Test (the controlling decision for Phases 3–8)

R1 from the Phase 1 design (`project_mpp_item_master_pattern.md`) is: **does `props.params.value` on the EmbedContainerConfig embedded view bidirectionally bind to `view.custom.editDraft.containerConfig` on the parent?**

The Phase 1 view shell wired the bindings on both sides — parent's `EmbedContainerConfig.props.params.value` has a property binding with `bidirectional: true` pointing at `view.custom.editDraft.containerConfig`, and the child's form fields inside `BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json` bidi-bind to `view.params.value.<field>`. Whether Ignition actually rejoins those two halves at runtime has never been exercised.

Phase 2 builds the test bed. The smoke verifies one round-trip on the simplest field (the `ClosureMethod` dropdown):

1. Click an Item row. Parent calls `BlueRidge.Parts.Item.getOne(id)` + `BlueRidge.Parts.ContainerConfig.getByItem(id)`. Parent writes both into `view.custom.selected` and `view.custom.editDraft` (deep clone).
2. With the ContainerConfig tab active, the child view's ClosureMethod dropdown should now show whatever the DB returned (e.g., `ByCount`).
3. User changes the dropdown to `ByWeight`.
4. **Pass:** the parent's `● Unsaved changes` label appears in the title bar, and inspecting `view.custom.editDraft.containerConfig.ClosureMethod` in Designer's property browser shows `ByWeight`.
5. **Fail:** dirty indicator stays blank and/or the parent's `editDraft.containerConfig.ClosureMethod` is unchanged.

### R1 fallback (only invoked if smoke fails)

The documented fallback per `project_mpp_item_master_pattern.md` is **page-scoped change messages from child up to parent, with the child owning its own draft slice**:

| Layer | Behavior |
|---|---|
| Parent | `props.params.value` becomes **input-only** (one-way down). Parent fires a `containerConfigPushed` page-scoped message every time it sets `editDraft.containerConfig` (on item selection). Receives `containerConfigChanged` page-scoped messages back from the child and writes payload into `editDraft.containerConfig`. |
| Child  | Holds its own `view.custom.editDraft` initialised from `view.params.value` (on `containerConfigPushed` page-scoped message). Form fields bidi-bind to `view.custom.editDraft.<field>`. Any field change fires `containerConfigChanged` page-scoped message with the full slice as payload. |

If the smoke fails, **stop**. Do not push Phase 2 code that depends on a broken bidi. The fallback design becomes its own brainstorming/plan cycle since it requires retrofitting all five tab children (Phase 1 mounted them; only ContainerConfig is wired with real data in Phase 2, but the pattern decision binds the other four).

## 3 — Architecture

### 3.1 — Layers (unchanged from Phase 1)

```
View bindings        -> view.custom.* (parent state) + view.params.value (child input)
view.scripts         -> calls BlueRidge.Parts.Item.* / BlueRidge.Parts.ContainerConfig.*
BlueRidge.Parts.*    -> calls BlueRidge.Common.Db.execList / execOne / execMutation
BlueRidge.Common.Db  -> the only layer that calls system.db.runNamedQuery
Named Queries        -> EXEC Parts.Item_List / Parts.Item_Get / Parts.ContainerConfig_GetByItem
Stored Procs         -> already exist; no SQL changes in Phase 2
```

### 3.2 — File deltas

**New:**

- `ignition/projects/MPP_Config/ignition/named-query/parts/Item_List/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Get/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_GetByItem/{query.sql, resource.json}`
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item/{code.py, resource.json}`
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/{code.py, resource.json}`

**Modified:**

- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` — replace the hardcoded `view.custom.items` array with a `runScript` binding driven by `view.custom.search` + `view.custom.typeFilter`; rewrite the `itemRowClicked` message handler to call live entity scripts; replace the per-item hardcoded `selected`/`editDraft` seeds with empty defaults that get overwritten on first selection.

**Not modified (Phase 2 boundary):**

- The five tab children (`ContainerConfig`, `Routes`, `Boms`, `QualitySpecs`, `Eligibility`) keep their Phase 1 shape exactly. ContainerConfig is the smoke target; the other four receive empty slices on selection and remain visually unchanged from Phase 1.
- No SQL changes. Tests stay at 937/937 (Phase 1 baseline, per PROJECT_STATUS).

### 3.3 — Data shapes

**Item list row (output of `BlueRidge.Parts.Item.mapItemRowsForList`):**

```python
{
  "id":            <int>,                # Parts.Item.Id
  "partNumber":    <str>,                # Parts.Item.PartNumber
  "description":   <str>,                # Parts.Item.Description
  "itemTypeId":    <int>,                # Parts.Item.ItemTypeId
  "itemTypeName":  <str>,                # Parts.ItemType.Name
  "typeBadge":     <str>,                # derived: FG / COMP / SA / RAW / PT
  "isDraft":       <bool>,               # always False in Phase 2 (no draft state yet)
}
```

**Item meta dict (output of `BlueRidge.Parts.Item.getOne`, used as `editDraft.meta`):**

```python
{
  "Id":               <int>,
  "PartNumber":       <str>,
  "Description":      <str>,
  "ItemTypeId":       <int>,
  "ItemTypeName":     <str>,
  "UomId":            <int>,
  "UomCode":          <str>,
  "MacolaPartNumber": <str|None>,
  "UnitWeight":       <decimal|None>,
  "WeightUomId":      <int|None>,
  "WeightUomCode":    <str|None>,
  "DefaultSubLotQty": <int|None>,
  "MaxLotSize":       <int|None>,
  "CountryOfOrigin":  <str|None>,
  "MaxParts":         <int|None>,
}
```

PartsPerBasket field that Phase 1's mockup data carried is **NOT** a column on `Parts.Item`. It was a dummy field in Phase 1's seeds. The InputPartsPerBasket bound to `editDraft.meta.PartsPerBasket` will simply show blank in Phase 2 — it's a Phase 1 oversight that won't surface a Designer error (Perspective tolerates missing keys silently). Leaving it for Phase 3 to remove cleanly.

**ContainerConfig dict (output of `BlueRidge.Parts.ContainerConfig.getByItem`, used as `editDraft.containerConfig`):**

```python
{
  "Id":                <int>,            # Parts.ContainerConfig.Id (NULL/absent if no active config)
  "ItemId":            <int>,
  "TraysPerContainer": <int>,
  "PartsPerTray":      <int>,
  "IsSerialized":      <bool>,
  "DunnageCode":       <str|None>,
  "CustomerCode":      <str|None>,
  "ClosureMethod":     <str|None>,       # ByCount | ByWeight | ByVision | NULL
  "TargetWeight":      <decimal|None>,
}
```

When `getByItem` returns `None` (no active ContainerConfig exists), the entity script returns an empty dict `{}`. The parent writes the empty dict into `editDraft.containerConfig`; the child's form fields show as blank.

**Other tab slices (defaults on Item selection):**

```python
"routes":       {"steps": []},
"boms":         {"lines": []},
"qualitySpecs": [],
"eligibility":  {"rows": []},
```

These match the shape each tab view consumes today, so the tabs render an "empty state" until their own phases populate.

### 3.4 — Items binding

The parent's `view.custom.items` becomes an expression binding:

```
runScript("BlueRidge.Parts.Item.getAllForList", 0, {view.custom.search}, {view.custom.typeFilter})
```

Where `getAllForList(self, searchText, typeFilter)` calls `getAll(searchText=searchText)` then runs `mapItemRowsForList(rows, typeFilter)` to filter-by-type-name client-side and shape to the list-row format. Server-side filter on `SearchText` for efficiency; client-side filter on `ItemTypeName` to avoid needing an `ItemType_List` NQ in Phase 2.

Polling interval: `0` (re-evaluate only when bound props change). Search and typeFilter both change → re-bind. After Phase 3's Save/Add lands, an explicit `system.perspective.refreshBinding('view.custom.items')` call will be issued from the mutation handlers. Not in Phase 2.

### 3.5 — itemRowClicked handler (new shape)

```python
clickedId = payload.get('id') if payload else None
if clickedId is None:
    return
itemMeta = BlueRidge.Parts.Item.getOne(clickedId)
if itemMeta is None:
    BlueRidge.Common.Notify.toast(
        'Item not found',
        'Item id %s no longer exists.' % clickedId,
        'warning',
    )
    return
ccRow = BlueRidge.Parts.ContainerConfig.getByItem(clickedId) or {}
bundle = {
    'meta':           dict(itemMeta),
    'containerConfig': dict(ccRow),
    'routes':         {'steps': []},
    'boms':           {'lines': []},
    'qualitySpecs':   [],
    'eligibility':    {'rows': []},
}
self.view.custom.selected  = bundle
self.view.custom.editDraft = {
    'meta':           dict(itemMeta),
    'containerConfig': dict(ccRow),
    'routes':         {'steps': []},
    'boms':           {'lines': []},
    'qualitySpecs':   [],
    'eligibility':    {'rows': []},
}
self.view.custom.mode = 'update'
```

Two distinct `dict(...)` copies of each slice so `editDraft` and `selected` are independent objects — otherwise the dirty indicator (which compares the two by identity / value) would never see them diverge after the user edits `editDraft`.

### 3.6 — Initial state at view open

Replace hardcoded `view.custom.selected` and `view.custom.editDraft` blocks (currently seeded with 5G0 Front Cover Assembly fixture) with empty defaults:

```json
"selected":  { "meta": {}, "containerConfig": {}, "routes": {"steps": []}, "boms": {"lines": []}, "qualitySpecs": [], "eligibility": {"rows": []} },
"editDraft": { "meta": {}, "containerConfig": {}, "routes": {"steps": []}, "boms": {"lines": []}, "qualitySpecs": [], "eligibility": {"rows": []} }
```

This avoids showing fake 5G0 data on first open. The title-bar dirty indicator binding compares the two; both being equal empty dicts → no dirty signal.

`view.custom.items` is removed from the static seed and becomes a runScript-bound property. `itemTypes` static dropdown options keep their hardcoded values for Phase 2 (typeFilter is operationally a name filter, not an Id filter).

## 4 — Named Query specifics

All three NQs:

- `scope: "DG"` (Designer / Gateway), `version: 2`, `database: "MPP"`.
- `type: "Query"` (not `UpdateQuery`) — read-only.
- `cacheEnabled: false` (consistent with project default).
- Parameter identifiers in camelCase (per pack convention).
- `sqlType` enum (per `feedback_ignition_nq_resource_schema.md`): `Int8 = 3` for BIGINT, `String = 7` for NVARCHAR, `Boolean = 6` for BIT.
- `lastModification.actor: "claude"`, `lastModificationSignature: ""` (forces Designer to treat as fresh).

### 4.1 — `parts/Item_List`

```sql
-- query.sql
EXEC Parts.Item_List
    @ItemTypeId        = :itemTypeId,
    @SearchText        = :searchText,
    @IncludeDeprecated = :includeDeprecated
```

Parameters:
- `itemTypeId` (sqlType 3 / Int8) — nullable; pass NULL to omit filter
- `searchText` (sqlType 7 / String) — nullable; LIKE filter on PartNumber+Description
- `includeDeprecated` (sqlType 6 / Boolean) — default 0

### 4.2 — `parts/Item_Get`

```sql
EXEC Parts.Item_Get
    @Id = :id
```

Parameters:
- `id` (sqlType 3 / Int8) — required

### 4.3 — `parts/ContainerConfig_GetByItem`

```sql
EXEC Parts.ContainerConfig_GetByItem
    @ItemId = :itemId
```

Parameters:
- `itemId` (sqlType 3 / Int8) — required

## 5 — Entity script specifics

### 5.1 — `BlueRidge.Parts.Item`

Mirrors `BlueRidge.Quality.DefectCode` shape (deep-unwrap inputs, route through `Common.Db`, log via `Common.Util.log`, error-toast on read failure with empty-list fallback).

Public surface:

```
getAll(searchText=None, itemTypeId=None, includeDeprecated=False)  -> list[dict]
getOne(itemId)                                                     -> dict | None
mapItemRowsForList(rows, typeFilter='All Types')                   -> list[dict]
typeBadgeFor(itemTypeName)                                         -> str
getAllForList(searchText='', typeFilter='All Types')               -> list[dict]   # composes the two
```

`typeBadgeFor`:

```python
{
    "Finished Good":  "FG",
    "Component":      "COMP",
    "Sub-Assembly":   "SA",
    "Raw Material":   "RAW",
    "Pass-Through":   "PT",
}.get(itemTypeName, "")
```

Unknown names → empty string badge. No exception.

`mapItemRowsForList(rows, typeFilter)`:

- Defensive against Dataset input (lesson from `feedback_ignition_lookup_dataset_only.md` + `filterAndMapRows` pattern in DefectCode).
- If `typeFilter == "All Types"` or empty / None → emit all rows.
- Otherwise → keep rows where `r['ItemTypeName'] == typeFilter`.
- Map each row to the list-row shape from §3.3 above.

### 5.2 — `BlueRidge.Parts.ContainerConfig`

Public surface:

```
getByItem(itemId)  -> dict | None
```

Single-function module in Phase 2. Phase 4 adds save / deprecate.

## 6 — Conventions checklist

- **NQ resource.json** v2 schema, `sqlType` enum (3 / 6 / 7), Designer-canonical field order. Reference: `quality/DefectCode_List/resource.json`.
- **No `system.db.*` in entity scripts.** Every DB call goes through `BlueRidge.Common.Db.execList` / `execOne`.
- **No OUTPUT params in any proc** — Phase 2 uses existing procs that already follow this rule.
- **Read funcs catch + toast** on DB exception, return `[]` or `None` as appropriate.
- **`_u()` deep-unwrap** at every public-handler entry that receives a Java-side value (incl. message payloads).
- **`BlueRidge.Common.Util.log(...)`** at entry of every public function (1-line, inspect-frame fills module + function).
- **camelCase NQ params**; PascalCase proc params (matches existing pattern).

## 7 — Out of scope (deferred)

| Item | Lands in |
|---|---|
| Item Create / Update / Deprecate procs called from UI | Phase 3 |
| Add Item modal wire-up to call Item.add() | Phase 3 |
| Save button on title bar wired to bundle save | Phase 3 |
| ContainerConfig Save (`ContainerConfig.update` / `_Create`) | Phase 4 |
| Routes tab live data | Phase 5 |
| BOMs tab live data | Phase 6 |
| Quality Specs tab live data | Phase 7 |
| Eligibility tab live data | Phase 8 |
| `ItemType_List` NQ (type filter resolves to ItemTypeId server-side) | Phase 3 or later if needed |
| Cleanup of `PartsPerBasket` field on the parent's Identity row (not a real column) | Phase 3 |

## 8 — Risks and verification

| Risk | Mitigation |
|---|---|
| **R1** — bidi `props.params.value` ↔ parent custom prop doesn't round-trip across the embed boundary | The Phase 2 smoke checklist (§9 below) is the verification. Stops Phase 3-8 if it fails; fallback design in §2. |
| Empty `getByItem` result (no active ContainerConfig) crashes the child view | Entity script returns `{}` (not `None`) when proc emits empty result set; child view fields show blank. |
| Designer caches the parent view and clobbers file edits | Jacques is not running Designer this session per the briefing. File-edit is safe under the close-first protocol (`feedback_ignition_view_edit_boundary.md`). |
| `runScript` binding called with null search/typeFilter | `getAllForList` defaults both args; entity script's `_u()` unwraps and treats None/empty as "no filter". |

## 9 — R1 smoke checklist (for Jacques to execute in Designer post-deploy)

After the worktree merges to main and the project syncs, in Designer:

1. **Cold open** Item Master view. **Pass:** empty title bar (no part number), empty Identity fields, empty Container Config tab. No `5G0` fixture data.
2. **Click Item row** (any item — the seed data has Honda 5G0 family loaded). **Pass:** Identity header populates (PartNumber, Description, ItemType badge, UOM). Container Config tab fields populate (TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, etc.). Dirty indicator stays empty (selected == editDraft).
3. **Open Designer property browser** on the parent view → expand `view.custom.editDraft.containerConfig`. **Pass:** keys match the DB row (ClosureMethod=ByCount, etc.).
4. **Change ClosureMethod dropdown** from `ByCount` to `ByWeight`. **Pass (R1 holds):** title-bar shows `● Unsaved changes` AND `view.custom.editDraft.containerConfig.ClosureMethod` shows `ByWeight` in the property browser. **Fail (R1 broken):** dirty indicator does not appear OR parent's editDraft.containerConfig.ClosureMethod is unchanged.
5. **Change ClosureMethod back** to `ByCount`. **Pass:** dirty indicator disappears.
6. **Click a different Item row.** **Pass:** Identity + Container Config tab re-populate with the new item's data. Other tabs (Routes/BOMs/Quality Specs/Eligibility) show their empty-state shells (no row data).
7. **Filter typeFilter dropdown** to "Component". **Pass:** items list refreshes, shows only Component-typed items.
8. **Type in search box** ("5G0"). **Pass:** items list refreshes via SQL LIKE filter; only matching items remain.

If steps 1–7 pass, R1 holds and Phase 3 can proceed on this pattern. If step 4 fails, the fallback design in §2 governs the rest of the rebuild.

## 10 — Open questions (none)

All design questions resolved within the brief and existing memory. No customer-facing decisions needed for Phase 2 (the underlying data model is locked; the proc surface already exists; the view layout is approved from Phase 1).

---

**Approval:** Self-approved under auto mode. Subject to Jacques's review of the spec post-write.
