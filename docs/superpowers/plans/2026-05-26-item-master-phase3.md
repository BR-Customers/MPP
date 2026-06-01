# Item Master Phase 3 — Implementation Plan (Identity section + Item CRUD)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Read `project_mpp_item_master_pattern` memory before starting** — it codifies the per-section ownership pattern this plan implements. The spec was written before that convention was codified; § 0 below reconciles the differences.

**Goal:** Carve the Identity section out of the parent ItemMaster view into its own embedded view following the per-section ownership pattern. Wire Item Create / Update / Deprecate end-to-end (AddItem popup + Identity embed Save/Discard/Deprecate). Add `CountryOfOrigin` + `MaxParts` to the editable Identity row. Replace dummy ItemType/UOM dropdowns with live NQ-bound options.

**Architecture:** Identity embed receives `params.value: itemId` (BIGINT, input-only); owns local `view.custom.selected` + `view.custom.editDraft` (full `Parts.Item` shape); has its own Save / Discard / Deprecate buttons; broadcasts `sectionDirtyChanged` on dirty-state transitions; listens for `sectionSaveRequested` / `sectionDiscardRequested`. Mirrors the ContainerConfig embed (`be207a5..2817cdd`). Parent ItemMaster swaps the current `DetailsHeader` placeholder block for the new Identity embed, removes `view.custom.selectedItem` + its runScript binding (no longer needed), and adds `itemsRefresh` + `itemDeprecated` page-scoped message handlers.

**Tech Stack:** Ignition Perspective 8.3 (file-based views), Jython 2.7, SQL Server 2022 (existing procs — no SQL changes). Caching disabled by default on lookup NQs per project convention.

---

## § 0 — Convention reconciliation (spec → reality)

The Phase 3 design spec (`docs/superpowers/specs/2026-05-20-item-master-phase3-design.md`) predates the per-section ownership convention codified on 2026-05-20 and landed in Phase 4 (`4e2f47d..2817cdd`). The spec assumes the **parent owns** `editDraft.meta` + `selected.meta` + `mode`, with Save/Deprecate buttons on the parent. Phase 4 demolished that state.

**Five deltas between spec text and this plan:**

1. **Identity becomes its own embed.** Per the convention memory: *"Identity — renders in the title-bar area, not in a tab. Its embed receives `params.value: itemId`; its Save button updates the Parts.Item row."* The spec's parent `BtnSave` / `BtnDeprecate` handlers (§ 6.2.1, § 6.2.2) move INSIDE the new Identity embed. The parent stops handling Item meta state entirely.

2. **`view.custom.selected` + `editDraft` move INTO the Identity embed.** Spec § 6.2 references `view.custom.editDraft.meta` and `view.custom.selected.meta` — those props don't exist on the Phase 4 parent. The Identity embed owns its own `view.custom.selected` + `view.custom.editDraft` LOCALLY (full Item-row shape, not nested under `meta`).

3. **`view.custom.mode` is dead.** Spec § 8 describes a `mode = "view" | "update"` state machine on the parent. Replaced by: when `selectedItemId` is null, the EmptyState component shows (current Phase 4 wiring); when set, the DetailArea (containing Identity embed + tabs) shows. No mode prop needed.

4. **Identity broadcasts `sectionDirtyChanged` like every other section.** Spec § 6.2.7-9 describes Identity dirty as `editDraft != selected`. Reframed: Identity emits `sectionDirtyChanged {section: "identity", isDirty: <bool>}` page-scoped on every dirty transition; parent's existing handler updates `view.custom.sectionDirty.identity`; the tab-disable-when-dirty mechanism (`itemMasterTabObjects` helper) automatically locks the other tabs when Identity is dirty. Identity also gets disabled when ANOTHER section is dirty (per the same helper — `disabled: anyDirty && key != activeTab`) — but Identity isn't in the tab list; the gate against editing Identity while another section is dirty is the **item-row click intercept** (already wired) plus the parent's tab-strip disabling other navigation.

5. **`itemRowClicked` handler simplifies.** Phase 2/4 spec/code currently does `BlueRidge.Parts.Item.getOne(clickedId)` and stuffs `meta` into `selected`/`editDraft`. Under the convention, the handler just writes `view.custom.selectedItemId = clickedId` (gated by sectionDirty popup as already wired). The Identity embed sees the change via its `params.value` onChange and fetches its own data.

**What stays the same:**

- The AddItem popup remains a discrete Create-only modal. It does NOT follow per-section ownership (it's a transient popup with its own draft, not a persistent section). Spec § 6.1 mostly applies, modulo the Identity-embed naming changes.
- The 5 NQs, the entity script structure (`add` / `update` / `deprecate` / `emptyMeta` on `BlueRidge.Parts.Item`; `getAll` / `getForDropdown` on the new `ItemType` and `Uom` modules), and the proc surfaces are exactly as the spec describes.
- The `Audit.ConfigLog` integration, the smoke checklist intent, the FK-guard error messages — all unchanged.
- The 5 immutability rules (PartNumber + ItemTypeId post-create immutable; everything else mutable).

**One additional simplification the spec didn't anticipate:**

- The `view.custom.selectedItem` prop + its `runScript("getOneOrEmpty", 0, {selectedItemId})` binding (added in `be207a5` for the read-only DetailsHeader) **goes away**. Identity embed fetches its own data on `params.value` change. `getOneOrEmpty` stays as a utility; it's still useful from the Identity embed's `load()` customMethod.

---

## File Structure

```
ignition/projects/MPP_Config/
├── ignition/
│   ├── named-query/parts/
│   │   ├── Item_Create/           [NEW]   query.sql + resource.json
│   │   ├── Item_Update/           [NEW]   query.sql + resource.json
│   │   ├── Item_Deprecate/        [NEW]   query.sql + resource.json
│   │   ├── ItemType_List/         [NEW]   query.sql + resource.json
│   │   └── Uom_List/              [NEW]   query.sql + resource.json
│   └── script-python/BlueRidge/Parts/
│       ├── Item/code.py           [MODIFY] add add() + update() + deprecate() + emptyMeta()
│       ├── ItemType/              [NEW]   code.py + resource.json
│       └── Uom/                   [NEW]   code.py + resource.json
└── com.inductiveautomation.perspective/views/BlueRidge/
    ├── Components/Parts/ItemMaster/
    │   └── Identity/              [NEW]   resource.json + view.json — new per-section embed
    ├── Components/Popups/
    │   └── AddItem/view.json      [HEAVY MODIFY] new draft shape, NQ dropdowns, Create wire, ConfirmUnsaved
    └── Views/Parts/ItemMaster/
        └── view.json              [HEAVY MODIFY] replace DetailsHeader with Identity embed; remove
                                                   view.custom.selectedItem; add itemsRefresh +
                                                   itemDeprecated message handlers
```

Reference files (read-only):

- `sql/migrations/repeatable/R__Parts_Item_Create.sql` — proc signature truth
- `sql/migrations/repeatable/R__Parts_Item_Update.sql` — proc signature truth
- `sql/migrations/repeatable/R__Parts_Item_Deprecate.sql`
- `sql/migrations/repeatable/R__Parts_ItemType_List.sql`
- `sql/migrations/repeatable/R__Parts_Uom_List.sql`
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json` — reference impl of a flat per-section editor (Identity follows the same template)
- `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/resource.json` — NQ resource.json reference (Create with NewId)
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Update/resource.json` — NQ reference (Update, no NewId)
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Deprecate/resource.json` — NQ reference (Deprecate, no NewId)
- `ignition/projects/MPP_Config/ignition/named-query/location/Location_ListByTier/resource.json` — NQ reference (List with BIT param)
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/code.py` — entity script CRUD shape reference
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonType/code.py` — entity script getForDropdown shape reference
- `docs/superpowers/specs/2026-05-20-item-master-phase3-design.md` — companion design spec (with § 0 deltas above applied)
- `mockup/index.html` lines 308–860 + 2629–2715 — Item Master layout reference

---

### Task 1: Create Named Query `parts/Item_Create`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Create/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Create/resource.json`

- [ ] **Step 1: Read DefectCode_Create reference resource.json** for canonical shape (v2 schema, attribute key order):

```powershell
Get-Content ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Create\resource.json
```

- [ ] **Step 2: Create query.sql**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Create/query.sql`

```sql
EXEC Parts.Item_Create
    @PartNumber       = :partNumber,
    @ItemTypeId       = :itemTypeId,
    @Description      = :description,
    @MacolaPartNumber = :macolaPartNumber,
    @DefaultSubLotQty = :defaultSubLotQty,
    @MaxLotSize       = :maxLotSize,
    @UomId            = :uomId,
    @UnitWeight       = :unitWeight,
    @WeightUomId      = :weightUomId,
    @CountryOfOrigin  = :countryOfOrigin,
    @MaxParts         = :maxParts,
    @AppUserId        = :appUserId
```

- [ ] **Step 3: Create resource.json**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Create/resource.json`

Use the same shape as `quality/DefectCode_Create/resource.json` (scope DG, version 2, type Query, database MPP, cacheEnabled false). Parameters in this exact order:

| param | sqlType | DB type |
|---|---|---|
| `partNumber` | `7` | NVARCHAR(50) |
| `itemTypeId` | `3` | BIGINT |
| `description` | `7` | NVARCHAR(500) |
| `macolaPartNumber` | `7` | NVARCHAR(50) |
| `defaultSubLotQty` | `2` | INT |
| `maxLotSize` | `2` | INT |
| `uomId` | `3` | BIGINT |
| `unitWeight` | `5` | DECIMAL(10,4) — Float8 is closest in Designer enum |
| `weightUomId` | `3` | BIGINT |
| `countryOfOrigin` | `7` | NVARCHAR(2) |
| `maxParts` | `2` | INT |
| `appUserId` | `3` | BIGINT |

(Sqlite check: sqlType `2` = Int4 = INT; `3` = Int8 = BIGINT; `5` = Float8 = FLOAT/DECIMAL coerce; `7` = String = NVARCHAR. Per `ignition-context-pack/04_named_queries.md`.)

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\Item_Create\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

Expected output: `OK`

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

Expected: `scanActive: true` then `scanActive: false`, no errors.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/Item_Create/
git commit -m "feat(item-master): NQ parts/Item_Create

Wraps Parts.Item_Create stored proc. Phase 3 add path."
```

---

### Task 2: Create Named Query `parts/Item_Update`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Update/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Update/resource.json`

- [ ] **Step 1: Read DefectCode_Update reference** for the no-NewId Update shape:

```powershell
Get-Content ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Update\resource.json
```

- [ ] **Step 2: Create query.sql**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Update/query.sql`

```sql
EXEC Parts.Item_Update
    @Id               = :id,
    @Description      = :description,
    @MacolaPartNumber = :macolaPartNumber,
    @DefaultSubLotQty = :defaultSubLotQty,
    @MaxLotSize       = :maxLotSize,
    @UomId            = :uomId,
    @UnitWeight       = :unitWeight,
    @WeightUomId      = :weightUomId,
    @CountryOfOrigin  = :countryOfOrigin,
    @MaxParts         = :maxParts,
    @AppUserId        = :appUserId
```

- [ ] **Step 3: Create resource.json**

Mirror DefectCode_Update shape. Parameters in this exact order:

| param | sqlType |
|---|---|
| `id` | `3` (Int8 / BIGINT) |
| `description` | `7` |
| `macolaPartNumber` | `7` |
| `defaultSubLotQty` | `2` |
| `maxLotSize` | `2` |
| `uomId` | `3` |
| `unitWeight` | `5` |
| `weightUomId` | `3` |
| `countryOfOrigin` | `7` |
| `maxParts` | `2` |
| `appUserId` | `3` |

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\Item_Update\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/Item_Update/
git commit -m "feat(item-master): NQ parts/Item_Update

Wraps Parts.Item_Update stored proc. Phase 3 update path."
```

---

### Task 3: Create Named Query `parts/Item_Deprecate`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Deprecate/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Deprecate/resource.json`

- [ ] **Step 1: Read DefectCode_Deprecate reference**

```powershell
Get-Content ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Deprecate\resource.json
```

- [ ] **Step 2: Create query.sql**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Deprecate/query.sql`

```sql
EXEC Parts.Item_Deprecate
    @Id        = :id,
    @AppUserId = :appUserId
```

- [ ] **Step 3: Create resource.json**

Parameters in this exact order:

| param | sqlType |
|---|---|
| `id` | `3` |
| `appUserId` | `3` |

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\Item_Deprecate\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/Item_Deprecate/
git commit -m "feat(item-master): NQ parts/Item_Deprecate

Wraps Parts.Item_Deprecate stored proc. FK-guards block deprecation
when active BOMs / RouteTemplates / ItemLocations / ContainerConfigs
reference the Item; the proc's Message field surfaces the specific
dependency."
```

---

### Task 4: Create Named Query `parts/ItemType_List`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ItemType_List/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ItemType_List/resource.json`

- [ ] **Step 1: Read an existing List NQ resource.json for reference shape**

```powershell
Get-Content ignition\projects\MPP_Config\ignition\named-query\location\Location_ListByTier\resource.json
```

- [ ] **Step 2: Create query.sql**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/ItemType_List/query.sql`

```sql
EXEC Parts.ItemType_List @IncludeDeprecated = :includeDeprecated
```

- [ ] **Step 3: Create resource.json**

Single parameter:

| param | sqlType |
|---|---|
| `includeDeprecated` | `6` (Boolean / BIT) |

Set `attributes.type` to `"Query"` (returns a rowset). Leave `cacheEnabled: false` for now (ItemTypes are slow-changing but Phase 3 keeps caching off per project default).

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\ItemType_List\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/ItemType_List/
git commit -m "feat(item-master): NQ parts/ItemType_List

Wraps Parts.ItemType_List. Backs the ItemType dropdown in the AddItem
popup."
```

---

### Task 5: Create Named Query `parts/Uom_List`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Uom_List/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Uom_List/resource.json`

- [ ] **Step 1: Create query.sql**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/Uom_List/query.sql`

```sql
EXEC Parts.Uom_List @IncludeDeprecated = :includeDeprecated
```

- [ ] **Step 2: Create resource.json**

Same shape as ItemType_List. Parameters:

| param | sqlType |
|---|---|
| `includeDeprecated` | `6` |

- [ ] **Step 3: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\Uom_List\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 4: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/Uom_List/
git commit -m "feat(item-master): NQ parts/Uom_List

Wraps Parts.Uom_List. Backs the UOM + Weight UOM dropdowns in the
AddItem popup and the Identity embed."
```

---

### Task 6: Create entity script `BlueRidge.Parts.ItemType`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ItemType/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ItemType/resource.json`

- [ ] **Step 1: Read DowntimeReasonType reference** for the `getForDropdown` shape and resource.json structure:

```powershell
Get-Content ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Oee\DowntimeReasonType\code.py
Get-Content ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Oee\DowntimeReasonType\resource.json
```

- [ ] **Step 2: Create resource.json**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ItemType/resource.json`

Mirror the DowntimeReasonType resource.json shape (scope, version, files, attributes.hintScope, lastModification).

- [ ] **Step 3: Create code.py**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ItemType/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Parts.ItemType
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          1.0
#
# Description:
#   Read surface for the ItemType lookup table. Backs the ItemType
#   dropdown in the AddItem popup. Routes through BlueRidge.Common.Db.*.
#
# Public surface:
#   getAll(includeDeprecated=False) -> list[dict]
#   getForDropdown(includeSelectPrompt=True) -> list[{label, value}]
#
# Change Log:
#   2026-05-26 - 1.0 - Initial version (Phase 3 — ItemType dropdown).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAll(includeDeprecated=False):
    """List ItemTypes ordered by Name. Returns list[dict] with keys
    {Id, Name, Description, DeprecatedAt}."""
    BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
    try:
        return BlueRidge.Common.Db.execList(
            "parts/ItemType_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load item types", str(e), "error")
        return []


def getForDropdown(includeSelectPrompt=True):
    """Returns [{label, value}] for the ItemType dropdown. Optional
    'Select...' first entry with value=None when includeSelectPrompt=True."""
    rows = getAll(False)
    options = [{"label": r.get("Name", ""), "value": r.get("Id")} for r in rows]
    if _u(includeSelectPrompt):
        options.insert(0, {"label": u"Select...", "value": None})
    return options
```

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Parts\ItemType\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Smoke from Designer Script Console** (deferred to user)

```python
print BlueRidge.Parts.ItemType.getAll()
print BlueRidge.Parts.ItemType.getForDropdown()
```

Expected: 5 rows (Raw Material / Component / Sub-Assembly / Finished Good / Pass-Through). `getForDropdown` returns 6 entries (5 + the "Select..." prompt).

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ItemType/
git commit -m "feat(item-master): BlueRidge.Parts.ItemType entity script

Read-only surface for the ItemType lookup table. Backs the ItemType
dropdown in the AddItem popup."
```

---

### Task 7: Create entity script `BlueRidge.Parts.Uom`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Uom/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Uom/resource.json`

- [ ] **Step 1: Create resource.json**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Uom/resource.json`

Same shape as the ItemType resource.json from Task 6.

- [ ] **Step 2: Create code.py**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Uom/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Parts.Uom
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          1.0
#
# Description:
#   Read surface for the Uom lookup table. Backs the UOM + Weight UOM
#   dropdowns in the AddItem popup and the Identity embed.
#
# Public surface:
#   getAll(includeDeprecated=False) -> list[dict]
#   getForDropdown(includeBlank=False, blankLabel=u"-") -> list[{label, value}]
#
# Change Log:
#   2026-05-26 - 1.0 - Initial version (Phase 3 — UOM dropdowns).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAll(includeDeprecated=False):
    """List UOMs ordered by Code. Returns list[dict] with keys
    {Id, Code, Name, DeprecatedAt}."""
    BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Uom_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load UOMs", str(e), "error")
        return []


def getForDropdown(includeBlank=False, blankLabel=u"-"):
    """Returns [{label, value}] for a UOM dropdown.

    - includeBlank=False (default) — counting UOM (required field). No
      blank entry; first option is the first real UOM.
    - includeBlank=True — Weight UOM (optional field). Inserts a blank
      entry at index 0 with value=None and label=blankLabel."""
    rows = getAll(False)
    options = [{"label": r.get("Code", ""), "value": r.get("Id")} for r in rows]
    if _u(includeBlank):
        options.insert(0, {"label": _u(blankLabel) or u"-", "value": None})
    return options
```

- [ ] **Step 3: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Parts\Uom\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 4: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Smoke from Designer Script Console** (deferred)

```python
print BlueRidge.Parts.Uom.getAll()
print BlueRidge.Parts.Uom.getForDropdown()                 # required field
print BlueRidge.Parts.Uom.getForDropdown(True)            # Weight UOM (optional)
```

Expected: at minimum 3 UOMs (EA / LB / KG). `getForDropdown(True)` has the `-` blank at index 0.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Uom/
git commit -m "feat(item-master): BlueRidge.Parts.Uom entity script

Read-only surface for the Uom lookup table. Backs the counting-UOM
dropdown (required) and the Weight-UOM dropdown (optional)."
```

---

### Task 8: Extend `BlueRidge.Parts.Item` with mutation surface

**Files:**
- Modify: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item/code.py`

- [ ] **Step 1: Read current Item code.py** to confirm Phase 2 + Phase 4 surface intact (Phase 4 left `getOneOrEmpty` + `itemMasterTabLabels` + `itemMasterTabObjects` in place).

```powershell
Get-Content ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Parts\Item\code.py
```

- [ ] **Step 2: Append four functions** to the end of the file (after `itemMasterTabObjects`):

```python


def add(meta):
    """Create a new Item. meta keys (camelCase OR PascalCase tolerated):
        partNumber, itemTypeId, description, macolaPartNumber,
        defaultSubLotQty, maxLotSize, uomId, unitWeight, weightUomId,
        countryOfOrigin, maxParts

    PartNumber and ItemTypeId are required (proc rejects nulls).
    Returns {Status, Message, NewId}.

    The proc enforces:
      - PartNumber uniqueness
      - ItemTypeId FK + not-deprecated
      - UomId FK + not-deprecated
      - WeightUomId required when UnitWeight supplied
      - MaxParts > 0 when supplied
      - CountryOfOrigin <= 2 chars
    """
    m = _u(meta) or {}
    BlueRidge.Common.Util.log("meta=%s" % m)
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_Create",
        {
            "partNumber":       m.get("partNumber")       or m.get("PartNumber"),
            "itemTypeId":       m.get("itemTypeId")       or m.get("ItemTypeId"),
            "description":      m.get("description")      or m.get("Description"),
            "macolaPartNumber": m.get("macolaPartNumber") or m.get("MacolaPartNumber"),
            "defaultSubLotQty": m.get("defaultSubLotQty") if m.get("defaultSubLotQty") is not None else m.get("DefaultSubLotQty"),
            "maxLotSize":       m.get("maxLotSize")       if m.get("maxLotSize")       is not None else m.get("MaxLotSize"),
            "uomId":            m.get("uomId")            or m.get("UomId"),
            "unitWeight":       m.get("unitWeight")       if m.get("unitWeight")       is not None else m.get("UnitWeight"),
            "weightUomId":      m.get("weightUomId")      or m.get("WeightUomId"),
            "countryOfOrigin":  m.get("countryOfOrigin")  or m.get("CountryOfOrigin"),
            "maxParts":         m.get("maxParts")         if m.get("maxParts")         is not None else m.get("MaxParts"),
            "appUserId":        BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(meta):
    """Update an existing Item in place. PartNumber + ItemTypeId are
    immutable per the proc; do not pass them. meta keys:
        Id, description, macolaPartNumber, defaultSubLotQty,
        maxLotSize, uomId, unitWeight, weightUomId,
        countryOfOrigin, maxParts

    Returns {Status, Message}.
    """
    m = _u(meta) or {}
    BlueRidge.Common.Util.log("meta=%s" % m)
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_Update",
        {
            "id":               m.get("Id")               or m.get("id"),
            "description":      m.get("Description")      or m.get("description"),
            "macolaPartNumber": m.get("MacolaPartNumber") or m.get("macolaPartNumber"),
            "defaultSubLotQty": m.get("DefaultSubLotQty") if m.get("DefaultSubLotQty") is not None else m.get("defaultSubLotQty"),
            "maxLotSize":       m.get("MaxLotSize")       if m.get("MaxLotSize")       is not None else m.get("maxLotSize"),
            "uomId":            m.get("UomId")            or m.get("uomId"),
            "unitWeight":       m.get("UnitWeight")       if m.get("UnitWeight")       is not None else m.get("unitWeight"),
            "weightUomId":      m.get("WeightUomId")      or m.get("weightUomId"),
            "countryOfOrigin":  m.get("CountryOfOrigin")  or m.get("countryOfOrigin"),
            "maxParts":         m.get("MaxParts")         if m.get("MaxParts")         is not None else m.get("maxParts"),
            "appUserId":        BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(itemId):
    """Soft-delete the Item by Id. Returns {Status, Message}. The proc's
    FK-guards reject deprecation when active Bom / BomLine /
    RouteTemplate / ItemLocation / ContainerConfig dependents exist;
    the Message field surfaces the specific dependency."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_Deprecate",
        {
            "id":        itemId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def emptyMeta():
    """Blank meta dict for the AddItem popup's initial state. Keys match
    what the popup's form fields bidi-bind to (camelCase)."""
    return {
        "partNumber":       "",
        "itemTypeId":       None,
        "description":      "",
        "macolaPartNumber": "",
        "defaultSubLotQty": None,
        "maxLotSize":       None,
        "uomId":            None,
        "unitWeight":       None,
        "weightUomId":      None,
        "countryOfOrigin":  "",
        "maxParts":         None,
    }
```

**Note on the key-tolerance pattern**: Spec § 5.1 R9. AddItem popup uses camelCase keys (matching the entity script's `add(meta)` natural argument names); the parent Identity embed will use PascalCase keys (matching `Parts.Item_Get`'s column aliases). Both modules call the same `add()`/`update()`, so the entity script reads both casings. The `if ... is not None else ...` ternary is for nullable numeric fields where `or` would coerce `0`/`0.0` to falsy and skip them.

- [ ] **Step 3: Update the file header version + change log** (already at v1.1 per Phase 4):

Bump version to `1.2` and add a 2026-05-26 entry:

```python
#   2026-05-26 - 1.2 - Phase 3: add() + update() + deprecate() + emptyMeta()
#                      mutation surface.
```

- [ ] **Step 4: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Smoke from Designer Script Console** (deferred)

```python
# Empty shape
print BlueRidge.Parts.Item.emptyMeta()

# Add a test item — pick valid IDs from your dev DB
result = BlueRidge.Parts.Item.add({
    "partNumber":  "PHASE3-SMOKE-001",
    "itemTypeId":  2,                     # Component
    "uomId":       1,                     # EA
    "description": "Phase 3 smoke test",
})
print result   # {Status: True, Message: ..., NewId: <int>}

# Update it
result = BlueRidge.Parts.Item.update({
    "Id":          <NewId from above>,
    "Description": "Phase 3 smoke test (updated)",
    "UomId":       1,
})
print result

# Deprecate it
result = BlueRidge.Parts.Item.deprecate(<NewId from above>)
print result
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item/code.py
git commit -m "feat(item-master): Item.add + update + deprecate + emptyMeta

Phase 3 mutation surface. Key-tolerance pattern (camelCase OR
PascalCase) on add/update bridges the AddItem popup (camelCase draft)
and Identity embed (PascalCase editDraft hydrated from Item_Get
columns)."
```

---

### Task 9: Create Identity embed view

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json`

This is a **NEW view** — safe for file edit per `feedback_ignition_view_edit_boundary`. Use Write tool.

Confirm Designer is closed OR has no Identity view open (this is a new view; no prior cache) before starting.

- [ ] **Step 1: Read ContainerConfig reference view** for the per-section ownership template:

```powershell
Get-Content ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\ItemMaster\ContainerConfig\view.json
```

Key elements to replicate in Identity:
- `view.custom.selected` + `view.custom.editDraft` (pre-shaped with all fields the form binds)
- `view.custom.isDirty` expression binding `{view.custom.editDraft} != {view.custom.selected}`
- `view.custom.isDirty` onChange that sends `sectionDirtyChanged` page-scoped
- `params.value: 0` with input-only paramDirection and onChange calling `self.rootContainer.load()`
- `root.scripts.customMethods`: `load`, `handleSave`, `handleDiscard`
- `root.scripts.messageHandlers`: `sectionSaveRequested`, `sectionDiscardRequested`
- Layout: HeaderRow with title + dirty-conditional Save/Discard/Deprecate buttons

- [ ] **Step 2: Read existing ContainerConfig resource.json** for resource.json shape:

```powershell
Get-Content ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\ItemMaster\ContainerConfig\resource.json
```

- [ ] **Step 3: Create Identity/resource.json**

Path: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/resource.json`

Use the ContainerConfig resource.json shape verbatim (scope, version, files=[view.json], lastModification.actor=claude).

- [ ] **Step 4: Create Identity/view.json**

Path: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json`

Full structure:

```json
{
  "custom": {
    "selected": {
      "Id": null,
      "PartNumber": null,
      "Description": null,
      "ItemTypeId": null,
      "ItemTypeName": null,
      "UomId": null,
      "UomCode": null,
      "WeightUomId": null,
      "WeightUomCode": null,
      "MacolaPartNumber": null,
      "CountryOfOrigin": null,
      "UnitWeight": null,
      "DefaultSubLotQty": null,
      "MaxLotSize": null,
      "MaxParts": null
    },
    "editDraft": {
      "Id": null,
      "PartNumber": null,
      "Description": null,
      "ItemTypeId": null,
      "ItemTypeName": null,
      "UomId": null,
      "UomCode": null,
      "WeightUomId": null,
      "WeightUomCode": null,
      "MacolaPartNumber": null,
      "CountryOfOrigin": null,
      "UnitWeight": null,
      "DefaultSubLotQty": null,
      "MaxLotSize": null,
      "MaxParts": null
    },
    "isDirty": false,
    "uomOptions": [],
    "uomOptionsWithBlank": []
  },
  "params": { "value": 0 },
  "propConfig": {
    "params.value": {
      "paramDirection": "input",
      "onChange": {
        "enabled": true,
        "script": "\tself.rootContainer.load()"
      }
    },
    "custom.isDirty": {
      "binding": {
        "type": "expr",
        "config": { "expression": "{view.custom.editDraft} != {view.custom.selected}" }
      },
      "onChange": {
        "enabled": true,
        "script": "\tsystem.perspective.sendMessage(\"sectionDirtyChanged\", payload={\"section\": \"identity\", \"isDirty\": bool(currentValue.value)}, scope=\"page\")"
      }
    },
    "custom.uomOptions": {
      "binding": {
        "type": "expr",
        "config": { "expression": "runScript(\"BlueRidge.Parts.Uom.getForDropdown\", 0)" }
      }
    },
    "custom.uomOptionsWithBlank": {
      "binding": {
        "type": "expr",
        "config": { "expression": "runScript(\"BlueRidge.Parts.Uom.getForDropdown\", 0, true)" }
      }
    }
  },
  "props": {
    "defaultSize": { "width": 1040, "height": 200 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "column",
      "style": {
        "classes": "detail-panel",
        "padding": "10px 14px",
        "gap": "8px"
      }
    },
    "children": [
      <HEADER ROW — see Step 5>,
      <FIELD ROW 1 — see Step 6>,
      <FIELD ROW 2 — see Step 7>,
      <FIELD ROW 3 — see Step 8>,
      <FIELD ROW 4 — see Step 9>
    ],
    "scripts": {
      "customMethods": [
        <LOAD — see Step 10>,
        <HANDLE_SAVE — see Step 11>,
        <HANDLE_DISCARD — see Step 12>,
        <HANDLE_DEPRECATE — see Step 13>
      ],
      "messageHandlers": [
        <SECTION_SAVE_REQUESTED — see Step 14>,
        <SECTION_DISCARD_REQUESTED — see Step 14>
      ]
    }
  }
}
```

(The `<...>` placeholders are subsections expanded in Steps 5–14. Assemble the full file with all subsections inlined before writing.)

- [ ] **Step 5: HeaderRow** — title + dirty-state visibility on action buttons.

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "HeaderRow" },
  "position": { "basis": "auto" },
  "props": { "direction": "row", "alignItems": "center", "style": { "gap": "8px" } },
  "children": [
    {
      "type": "ia.display.label",
      "meta": { "name": "SummaryText" },
      "position": { "basis": "auto" },
      "propConfig": {
        "props.text": {
          "binding": {
            "type": "expr",
            "config": { "expression": "coalesce({view.custom.editDraft.PartNumber}, '') + ' — ' + coalesce({view.custom.editDraft.Description}, '')" }
          }
        }
      },
      "props": { "style": { "fontSize": "13px", "fontWeight": "600" } }
    },
    {
      "type": "ia.display.label",
      "meta": { "name": "SummaryBadge" },
      "position": { "basis": "auto" },
      "propConfig": {
        "props.text": {
          "binding": {
            "type": "property",
            "config": { "path": "view.custom.editDraft.ItemTypeName" }
          }
        }
      },
      "props": { "style": { "classes": "badge badge-published" } }
    },
    {
      "type": "ia.display.label",
      "meta": { "name": "HeaderSpacer" },
      "position": { "grow": 1 },
      "props": { "text": "" }
    },
    {
      "type": "ia.input.button",
      "meta": { "name": "BtnDiscard" },
      "position": { "basis": "auto" },
      "propConfig": {
        "meta.visible": {
          "binding": { "type": "property", "config": { "path": "view.custom.isDirty" } }
        }
      },
      "props": { "text": "Discard", "style": { "classes": "btn btn-sm" } },
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script",
            "scope": "G",
            "config": { "script": "\tself.view.rootContainer.handleDiscard()" }
          }
        }
      }
    },
    {
      "type": "ia.input.button",
      "meta": { "name": "BtnSave" },
      "position": { "basis": "auto" },
      "propConfig": {
        "meta.visible": {
          "binding": { "type": "property", "config": { "path": "view.custom.isDirty" } }
        }
      },
      "props": { "text": "Save", "style": { "classes": "btn btn-primary btn-sm" } },
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script",
            "scope": "G",
            "config": { "script": "\tself.view.rootContainer.handleSave()" }
          }
        }
      }
    },
    {
      "type": "ia.input.button",
      "meta": { "name": "BtnDeprecate" },
      "position": { "basis": "auto" },
      "props": { "text": "Deprecate", "style": { "classes": "btn btn-danger btn-sm" } },
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script",
            "scope": "G",
            "config": { "script": "\tself.view.rootContainer.handleDeprecate()" }
          }
        }
      }
    }
  ]
}
```

(Deprecate button is always visible when an item is loaded; its visibility-on-load is gated by `params.value > 0` in a future polish — for Phase 3 it's always visible. The button's `handleDeprecate` no-ops gracefully when no item is loaded.)

- [ ] **Step 6: FieldRow 1** — PartNumber (read-only), Item Type (read-only text), UOM (editable dropdown).

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "FieldRow1" },
  "position": { "basis": "auto" },
  "props": { "direction": "row", "style": { "classes": "field-row", "gap": "12px" } },
  "children": [
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldPartNumber" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Part Number", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.PartNumber" } } } },
          "props": { "enabled": false,
            "style": { "background": "var(--mpp-surface-card)", "classes": "search-input", "color": "var(--mpp-text-muted)", "width": "160px" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldItemType" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Item Type", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": false, "path": "view.custom.editDraft.ItemTypeName" } } } },
          "props": { "enabled": false,
            "style": { "background": "var(--mpp-surface-card)", "classes": "search-input", "color": "var(--mpp-text-muted)", "width": "160px" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldUom" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "UOM", "style": { "classes": "field-label" } } },
        { "type": "ia.input.dropdown", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": {
            "props.value": { "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.UomId" } } },
            "props.options": { "binding": { "type": "property",
              "config": { "path": "view.custom.uomOptions" } } }
          },
          "props": { "style": { "classes": "select", "width": "120px" } } }
      ]
    }
  ]
}
```

PartNumber + ItemType inputs are `enabled: false` (read-only — both immutable post-create per the proc and per spec § 3). UOM is editable (dropdown sourced from `view.custom.uomOptions`).

- [ ] **Step 7: FieldRow 2** — Description (editable), Macola Part # (editable).

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "FieldRow2" },
  "position": { "basis": "auto" },
  "props": { "direction": "row", "style": { "classes": "field-row", "gap": "12px" } },
  "children": [
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldDescription" },
      "position": { "basis": "200px", "grow": 2 },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Description", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.Description" } } } },
          "props": { "style": { "classes": "search-input", "width": "100%" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldMacola" },
      "position": { "basis": "100px", "grow": 1 },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Macola Part #", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.MacolaPartNumber" } } } },
          "props": { "style": { "classes": "search-input", "width": "100%" } } }
      ]
    }
  ]
}
```

- [ ] **Step 8: FieldRow 3** — Unit Weight, Weight UOM (dropdown with blank), Default Sub-Lot Qty, Parts Per Basket (binds to MaxLotSize).

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "FieldRow3" },
  "position": { "basis": "auto" },
  "props": { "direction": "row", "style": { "classes": "field-row", "gap": "12px" } },
  "children": [
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldUnitWeight" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Unit Weight", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.UnitWeight" } } } },
          "props": { "style": { "classes": "search-input", "width": "100px" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldWeightUom" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Weight UOM", "style": { "classes": "field-label" } } },
        { "type": "ia.input.dropdown", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": {
            "props.value": { "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.WeightUomId" } } },
            "props.options": { "binding": { "type": "property",
              "config": { "path": "view.custom.uomOptionsWithBlank" } } }
          },
          "props": { "style": { "classes": "select", "width": "120px" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldDefaultSubLotQty" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Default Sub-Lot Qty", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.DefaultSubLotQty" } } } },
          "props": { "style": { "classes": "search-input", "width": "100px" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldPartsPerBasket" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Parts Per Basket", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.MaxLotSize" } } } },
          "props": { "style": { "classes": "search-input", "width": "100px" } } }
      ]
    }
  ]
}
```

Note: the user-facing label stays "Parts Per Basket" (mockup wording), but the bidi path is `editDraft.MaxLotSize` (the actual backing column per spec § 7).

- [ ] **Step 9: FieldRow 4 (NEW)** — Country of Origin, MaxParts.

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "FieldRow4" },
  "position": { "basis": "auto" },
  "props": { "direction": "row", "style": { "classes": "field-row", "gap": "12px" } },
  "children": [
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldCountryOfOrigin" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Country of Origin", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.CountryOfOrigin" } } } },
          "props": { "placeholder": "US, JP, MX, ...",
            "style": { "classes": "search-input", "width": "120px" } } }
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": { "name": "FieldMaxParts" },
      "position": { "basis": "auto" },
      "props": { "direction": "column", "style": { "classes": "field", "gap": "2px" } },
      "children": [
        { "type": "ia.display.label", "meta": { "name": "Label" }, "position": { "basis": "auto" },
          "props": { "text": "Max Parts (per container)", "style": { "classes": "field-label" } } },
        { "type": "ia.input.text-field", "meta": { "name": "Input" }, "position": { "basis": "auto" },
          "propConfig": { "props.text": {
            "binding": { "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.MaxParts" } } } },
          "props": { "placeholder": "Optional",
            "style": { "classes": "search-input", "width": "120px" } } }
      ]
    }
  ]
}
```

- [ ] **Step 10: customMethod `load`**

```json
{
  "name": "load",
  "params": [],
  "script": "\titemId = self.view.params.value\n\trow = BlueRidge.Parts.Item.getOneOrEmpty(itemId)\n\tloaded = {\n\t\t\"Id\":               row.get(\"Id\"),\n\t\t\"PartNumber\":       row.get(\"PartNumber\"),\n\t\t\"Description\":      row.get(\"Description\"),\n\t\t\"ItemTypeId\":       row.get(\"ItemTypeId\"),\n\t\t\"ItemTypeName\":     row.get(\"ItemTypeName\"),\n\t\t\"UomId\":            row.get(\"UomId\"),\n\t\t\"UomCode\":          row.get(\"UomCode\"),\n\t\t\"WeightUomId\":      row.get(\"WeightUomId\"),\n\t\t\"WeightUomCode\":    row.get(\"WeightUomCode\"),\n\t\t\"MacolaPartNumber\": row.get(\"MacolaPartNumber\"),\n\t\t\"CountryOfOrigin\":  row.get(\"CountryOfOrigin\"),\n\t\t\"UnitWeight\":       row.get(\"UnitWeight\"),\n\t\t\"DefaultSubLotQty\": row.get(\"DefaultSubLotQty\"),\n\t\t\"MaxLotSize\":       row.get(\"MaxLotSize\"),\n\t\t\"MaxParts\":         row.get(\"MaxParts\"),\n\t}\n\tself.view.custom.selected  = dict(loaded)\n\tself.view.custom.editDraft = dict(loaded)"
}
```

`getOneOrEmpty` returns the full key-shape with null values when itemId is null/missing — so the form fields render clean even when no item is selected.

- [ ] **Step 11: customMethod `handleSave`**

```json
{
  "name": "handleSave",
  "params": [],
  "script": "\tdraft = self.view.custom.editDraft or {}\n\titemId = draft.get(\"Id\")\n\tif not itemId:\n\t\tBlueRidge.Common.Notify.toast(\"Nothing to save\", \"Select an item first.\", \"warning\")\n\t\treturn\n\tif not draft.get(\"UomId\"):\n\t\tBlueRidge.Common.Notify.toast(\"UOM required\", \"Pick a UOM before saving.\", \"warning\")\n\t\treturn\n\tdef _toNum(v):\n\t\tif v is None or v == \"\":\n\t\t\treturn None\n\t\ttry:\n\t\t\treturn int(v)\n\t\texcept (ValueError, TypeError):\n\t\t\ttry:\n\t\t\t\treturn float(v)\n\t\t\texcept (ValueError, TypeError):\n\t\t\t\treturn None\n\tpayload = dict(draft)\n\tpayload[\"DefaultSubLotQty\"] = _toNum(draft.get(\"DefaultSubLotQty\"))\n\tpayload[\"MaxLotSize\"]       = _toNum(draft.get(\"MaxLotSize\"))\n\tpayload[\"UnitWeight\"]       = _toNum(draft.get(\"UnitWeight\"))\n\tpayload[\"MaxParts\"]         = _toNum(draft.get(\"MaxParts\"))\n\tresult = BlueRidge.Parts.Item.update(payload)\n\tBlueRidge.Common.Ui.notifyResult(result, \"Item updated\")\n\tif result and result.get(\"Status\"):\n\t\tself.load()\n\t\tsystem.perspective.sendMessage(\"itemsRefresh\", scope=\"page\")"
}
```

The `_toNum` coercion handles text-field bidi writing strings into editDraft (per the same pattern as ContainerConfig handleSave in `981b816`).

- [ ] **Step 12: customMethod `handleDiscard`**

```json
{
  "name": "handleDiscard",
  "params": [],
  "script": "\tself.view.custom.editDraft = dict(self.view.custom.selected)"
}
```

- [ ] **Step 13: customMethod `handleDeprecate`**

```json
{
  "name": "handleDeprecate",
  "params": [],
  "script": "\titemId = (self.view.custom.editDraft or {}).get(\"Id\") or (self.view.custom.selected or {}).get(\"Id\")\n\tif not itemId:\n\t\treturn\n\tresult = BlueRidge.Parts.Item.deprecate(itemId)\n\tBlueRidge.Common.Ui.notifyResult(result, \"Item deprecated\")\n\tif result and result.get(\"Status\"):\n\t\tsystem.perspective.sendMessage(\"itemsRefresh\", scope=\"page\")\n\t\tsystem.perspective.sendMessage(\"itemDeprecated\", payload={\"id\": itemId}, scope=\"page\")"
}
```

Two page messages on success:
- `itemsRefresh` — parent refreshes the items list binding (the deprecated item disappears when `includeDeprecated=false`).
- `itemDeprecated {id}` — parent clears `selectedItemId` if it matches the deprecated id (cascades all sections to empty-shape).

Spec § 6.2.2 declined a client-side confirmation popup; FK-guards on the proc are the safety net. Added to the polish/follow-ups list.

- [ ] **Step 14: messageHandlers**

```json
[
  {
    "messageType": "sectionSaveRequested",
    "pageScope": true,
    "sessionScope": false,
    "viewScope": false,
    "script": "\tif payload and payload.get(\"section\") == \"identity\":\n\t\tself.handleSave()"
  },
  {
    "messageType": "sectionDiscardRequested",
    "pageScope": true,
    "sessionScope": false,
    "viewScope": false,
    "script": "\tif payload and payload.get(\"section\") == \"identity\":\n\t\tself.handleDiscard()"
  }
]
```

`self` is the root component at the messageHandler scope (per `ignition-view-customMethods-scope` memory).

- [ ] **Step 15: Assemble full view.json** by inlining Steps 5–14 into the structure in Step 4. Write the file with the Write tool.

- [ ] **Step 16: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\ItemMaster\Identity\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 17: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 18: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/
git commit -m "feat(item-master): Identity embed (per-section ownership)

Carves Identity out of the parent ItemMaster view into its own embed
following the per-section ownership pattern (mirrors ContainerConfig in
981b816). Embed owns local selected + editDraft (full Parts.Item shape),
fetches via Item.getOneOrEmpty on params.value (itemId) change, has its
own HeaderRow with Save / Discard / Deprecate buttons (Save + Discard
gated by isDirty; Deprecate always visible).

UOM dropdowns sourced from BlueRidge.Parts.Uom.getForDropdown — counting
UOM (required, no blank) for FieldRow 1; Weight UOM (optional, with blank
entry) for FieldRow 3.

Adds two fields not in Phase 1 mockup but specified by FDS-03-001 + OI-12:
CountryOfOrigin (2-char text), MaxParts (numeric > 0 when supplied).

PartNumber + Item Type inputs are enabled: false (immutable post-create
per the proc).

Broadcasts sectionDirtyChanged {section: 'identity', isDirty} page-scoped
on dirty transitions. Listens for sectionSaveRequested / sectionDiscardRequested.
handleSave coerces text-field-string input to numeric for the four
nullable numeric fields. handleDeprecate fires both itemsRefresh and
itemDeprecated {id} on success."
```

---

### Task 10: Wire AddItem popup

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/view.json`

**This is an EXISTING view edit.** Per `feedback_ignition_view_edit_boundary`, edits to existing views default to Designer. Two execution options here:

- **(Preferred)** Open AddItem.view.json in Designer; make the changes via the property panel; verify with a manual smoke before file-saving. The agent should print explicit Designer-step instructions.
- **(Fallback if Designer is closed and the user confirms)** File-edit the JSON directly, using the Designer unicode-escape pattern from `feedback_ignition_designer_unicode_escapes` for any literal `=`, `'`, `<`, `>` inside scripts.

For this task, the plan documents the FILE-EDIT recipe (with Designer-step equivalents in italics). If the user has Designer open with AddItem.view.json loaded, do the Designer steps instead.

- [ ] **Step 1: Read AddItem/view.json** to capture current structure (form-field meta names, current binding paths to `view.custom.draft.*` keys).

```powershell
Get-Content ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\AddItem\view.json
```

Note the current draft-key naming. Phase 1 used PascalCase + Name/Code keys (`PartNumber`, `ItemTypeName`, `UomCode`); Phase 3 repoints to camelCase + Id keys.

- [ ] **Step 2: Replace `view.custom.draft` initial value** with the camelCase shape:

(*Designer: open the view, click the root component, in the property panel under Custom Properties expand `draft` and re-key each field, OR delete `draft` and re-add with the new shape.*)

```json
"draft": {
  "partNumber":       "",
  "itemTypeId":       null,
  "description":      "",
  "macolaPartNumber": "",
  "defaultSubLotQty": null,
  "maxLotSize":       null,
  "uomId":            null,
  "unitWeight":       null,
  "weightUomId":      null,
  "countryOfOrigin":  "",
  "maxParts":         null
}
```

- [ ] **Step 3: Add `view.custom.selected`** with identical shape as the dirty-baseline:

(*Designer: add a new Custom Property `selected` (object), paste the same shape as `draft`.*)

```json
"selected": {
  "partNumber":       "",
  "itemTypeId":       null,
  "description":      "",
  "macolaPartNumber": "",
  "defaultSubLotQty": null,
  "maxLotSize":       null,
  "uomId":            null,
  "unitWeight":       null,
  "weightUomId":      null,
  "countryOfOrigin":  "",
  "maxParts":         null
}
```

- [ ] **Step 4: Add `view.custom.isDirty`** with expression binding:

(*Designer: add a new Custom Property `isDirty` (boolean), edit its binding to Expression: `{view.custom.draft} != {view.custom.selected}`.*)

```json
"isDirty": {
  "binding": {
    "type": "expr",
    "config": { "expression": "{view.custom.draft} != {view.custom.selected}" }
  }
}
```

(Placed in `propConfig`, not `custom`.)

- [ ] **Step 5: Rebind PartNumber input** to `view.custom.draft.partNumber`.

(*Designer: select PartNumber input, edit `props.text` binding path.*)

Old: `view.custom.draft.PartNumber`
New: `view.custom.draft.partNumber`

- [ ] **Step 6: Replace ItemType dropdown** — bind options to NQ; bind value bidi to `view.custom.draft.itemTypeId` (BIGINT, not the name string).

(*Designer: select ItemType dropdown. Delete the hardcoded options. Add binding on `props.options`: Expression, `runScript("BlueRidge.Parts.ItemType.getForDropdown", 0)`. Edit `props.value` binding path → `view.custom.draft.itemTypeId`.*)

Old options: hardcoded `["Raw Material", "Component", ...]`.
New options binding: `runScript("BlueRidge.Parts.ItemType.getForDropdown", 0)`
Old value path: `view.custom.draft.ItemTypeName`
New value path: `view.custom.draft.itemTypeId` (bidi)

- [ ] **Step 7: Replace UOM dropdown** — same pattern, counting UOM (required).

Old options: hardcoded `["EA", "LB", "KG"]`.
New options binding: `runScript("BlueRidge.Parts.Uom.getForDropdown", 0)` (no blank — required field)
Old value path: `view.custom.draft.UomCode`
New value path: `view.custom.draft.uomId` (bidi)

- [ ] **Step 8: Replace Weight UOM dropdown** — same pattern, with blank entry.

New options binding: `runScript("BlueRidge.Parts.Uom.getForDropdown", 0, true)` (third arg = includeBlank)
Old value path: `view.custom.draft.WeightUomCode`
New value path: `view.custom.draft.weightUomId` (bidi)

- [ ] **Step 9: Rebind Description, Macola, UnitWeight, DefaultSubLotQty, PartsPerBasket inputs** to the camelCase keys.

| UI field | Old binding path | New binding path |
|---|---|---|
| Description | `view.custom.draft.Description` | `view.custom.draft.description` |
| Macola Part # | `view.custom.draft.MacolaPartNumber` | `view.custom.draft.macolaPartNumber` |
| Unit Weight | `view.custom.draft.UnitWeight` | `view.custom.draft.unitWeight` |
| Default Sub-Lot Qty | `view.custom.draft.DefaultSubLotQty` | `view.custom.draft.defaultSubLotQty` |
| Parts Per Basket | `view.custom.draft.PartsPerBasket` | `view.custom.draft.maxLotSize` (note: label stays, path repoints) |

- [ ] **Step 10: Add Country of Origin field**

(*Designer: in the Identity section of the popup, add a new field container with label + text-field. Bind text-field `props.text` to `view.custom.draft.countryOfOrigin` bidi.*)

Layout: text-field with `placeholder: "US, JP, MX, ..."`, width 120px, classes `search-input`.

- [ ] **Step 11: Add Max Parts field**

(*Designer: in the LOT Configuration section, add a new field container. Label "Max Parts (per container)". Text-field, `placeholder: "Optional"`, bind `props.text` bidi to `view.custom.draft.maxParts`.*)

- [ ] **Step 12: Wire BtnCreate** — replace the placeholder toast with the real create call.

(*Designer: select BtnCreate. Edit its `events.component.onActionPerformed`. Change scope to "G". Replace script body with the snippet below.*)

```python
draft  = self.view.custom.draft
result = BlueRidge.Parts.Item.add(draft)
BlueRidge.Common.Ui.notifyResult(result, "Item created")
if result and result.get("Status"):
    system.perspective.sendMessage("itemsRefresh", scope="page")
    system.perspective.closePopup(id="mpp-add-item")
```

`scope: "G"` is required because the script calls `system.perspective.*` (per `feedback-ignition-popup-open-scope` memory generalization).

- [ ] **Step 13: Wire CloseIcon + BtnCancel** with ConfirmUnsaved guard.

(*Designer: select CloseIcon (header X). Edit its onClick. Change scope to "G". Replace script with the snippet below. Repeat for BtnCancel.*)

```python
if self.view.custom.draft == self.view.custom.selected:
    system.perspective.closePopup(id="mpp-add-item")
else:
    system.perspective.openPopup(
        id="mpp-confirm-unsaved",
        view="BlueRidge/Components/Popups/ConfirmUnsaved",
        modal=True,
        showCloseIcon=False,
        params={
            "title":   "Discard New Item?",
            "message": "You have started filling out this form. Discard before closing?",
        },
    )
```

- [ ] **Step 14: Add `confirmUnsavedResult` message handler on root**

(*Designer: select the root component. Open the Scripts tab. Add a new message handler with messageType `confirmUnsavedResult`, page-scoped. Paste the script below.*)

```python
action = payload.get("action") if payload else None
if action == "save":
    # Re-run BtnCreate's logic
    result = BlueRidge.Parts.Item.add(self.view.custom.draft)
    BlueRidge.Common.Ui.notifyResult(result, "Item created")
    if result and result.get("Status"):
        system.perspective.sendMessage("itemsRefresh", scope="page")
        system.perspective.closePopup(id="mpp-add-item")
elif action == "discard":
    system.perspective.closePopup(id="mpp-add-item")
# action == "cancel" -> no-op
```

- [ ] **Step 15: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Popups\AddItem\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 16: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 17: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/
git commit -m "feat(item-master): wire AddItem popup to Item.add

Replaces hardcoded ItemType and UOM dropdown options with NQ-bound
options via BlueRidge.Parts.ItemType / Uom getForDropdown helpers.
Rebuilds view.custom.draft as camelCase + Id-keyed (matches the entity
script's add(meta) signature). Adds Country of Origin and Max Parts
fields. BtnCreate calls Item.add and on success fires itemsRefresh +
closes the popup. CloseIcon and BtnCancel route through ConfirmUnsaved
when the form is dirty."
```

---

### Task 11: Rewire parent ItemMaster view

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json`

**This is an EXISTING view edit.** Same Designer-vs-file boundary considerations as Task 10. Confirm Designer state before file-editing.

Goal of this task:
- **Replace** the current `DetailsHeader` (which is the read-only display added in `be207a5`) with an Embedded View reference to `BlueRidge/Components/Parts/ItemMaster/Identity`.
- **Remove** `view.custom.selectedItem` and its runScript binding — Identity owns its own data fetch.
- **Add** `itemsRefresh` and `itemDeprecated` page-scoped message handlers on root.
- **Add** `BtnAddItem` scope verification (R2 in spec): if the popup-open with `scope: "C"` doesn't fire in smoke, flip to `"G"`.

- [ ] **Step 1: Read current ItemMaster view.json** to confirm Phase 4 state intact (sectionDirty, pendingSwitch, selectedItemId props all present; DetailsHeader containing the read-only display; selectedItem prop + binding present).

- [ ] **Step 2: Remove `view.custom.selectedItem`** from the custom block.

(*Designer: select the root component. Custom Properties panel: right-click `selectedItem` → Delete.*)

Removes the pre-shaped 21-key default block plus its runScript binding in propConfig.

- [ ] **Step 3: Remove the `custom.selectedItem` binding from propConfig.**

(*Designer: removing the prop in Step 2 auto-removes its binding entry.*)

- [ ] **Step 4: Replace `DetailsHeader` with an Identity embed reference.**

The current `DetailsHeader` is a 660-line flex-column subtree (SummaryRow + 4 FieldRows). Replace the entire subtree with a single Embedded View pointing at `BlueRidge/Components/Parts/ItemMaster/Identity`.

(*Designer: in the Project Browser, navigate to the parent view's DetailArea → DetailsHeader. Delete the DetailsHeader component. Drag an Embedded View component in its place. Set `props.path` to `BlueRidge/Components/Parts/ItemMaster/Identity`. Bind `props.params.value` to `view.custom.selectedItemId` (one-way property binding).*)

Replacement JSON shape (for file-edit fallback):

```json
{
  "type": "ia.display.view",
  "meta": { "name": "Identity" },
  "position": { "basis": "auto" },
  "propConfig": {
    "props.params.value": {
      "binding": {
        "type": "property",
        "config": { "path": "view.custom.selectedItemId" }
      }
    }
  },
  "props": {
    "path": "BlueRidge/Components/Parts/ItemMaster/Identity",
    "useDefaultViewWidth": false,
    "useDefaultViewHeight": false,
    "params": { "value": 0 }
  }
}
```

Place this as the first child of `DetailArea.children` (currently `[DetailsHeader, TabContainer_0]` becomes `[Identity, TabContainer_0]`).

- [ ] **Step 5: Add `itemsRefresh` message handler** on root.

(*Designer: root → Scripts → Message Handlers → Add.*)

```json
{
  "messageType": "itemsRefresh",
  "pageScope": true,
  "sessionScope": false,
  "viewScope": false,
  "script": "\tsystem.perspective.refreshBinding(\"view.custom.items\")"
}
```

- [ ] **Step 6: Add `itemDeprecated` message handler** on root.

```json
{
  "messageType": "itemDeprecated",
  "pageScope": true,
  "sessionScope": false,
  "viewScope": false,
  "script": "\tdeprecatedId = payload.get(\"id\") if payload else None\n\tif deprecatedId is not None and deprecatedId == self.view.custom.selectedItemId:\n\t\tself.view.custom.selectedItemId = None"
}
```

This clears the parent's selectedItemId when the currently-selected item is deprecated. All section embeds then receive `params.value = None`, their `load()` runs, fields clear, EmptyState shows.

- [ ] **Step 7: Smoke `BtnAddItem` scope** (R2 from spec § 6.2.4).

Phase 1 wired BtnAddItem with `events.component.onActionPerformed.scope: "C"` and `type: "popup"` (native popup event, not script). The memory's no-op rule targets script events. Test as-is first.

(*Designer: click `+ Add Item` button. If the modal opens, leave scope as-is. If nothing happens, edit the event and change `scope: "C"` → `"G"`.*)

If file-editing required, the change is:
- Find: `"scope": "C"` inside the BtnAddItem `events.component.onActionPerformed` block
- Replace: `"scope": "G"`

- [ ] **Step 8: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Views\Parts\ItemMaster\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 9: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 10: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "refactor(item-master): swap DetailsHeader for Identity embed

Replaces the 660-line read-only DetailsHeader subtree (added in be207a5
as a Phase 3 prep placeholder) with an Embedded View reference to
BlueRidge/Components/Parts/ItemMaster/Identity. The Identity embed owns
its own state via per-section ownership; the parent passes only
params.value: selectedItemId (BIGINT, input-only).

Removes view.custom.selectedItem prop + its getOneOrEmpty runScript
binding (no longer needed — Identity embed fetches its own data on
params.value change).

Adds two new page-scoped message handlers on root:
- itemsRefresh: refreshBinding(view.custom.items) — triggered after
  Save/Create/Deprecate to refresh the items list.
- itemDeprecated {id}: clears selectedItemId when the deprecated item
  matches the current selection.

BtnAddItem scope: kept as 'C' per Phase 1 (native popup event). Smoke
will verify; flip to 'G' if the popup doesn't open."
```

---

### Task 12: Designer smoke + Phase 3 close-out (manual, deferred)

For Jacques, post-merge.

- [ ] **Step 1: Pull latest main**

```bash
git pull --ff-only origin main
```

- [ ] **Step 2: Run gateway scan once more**

```powershell
.\scan.ps1
```

- [ ] **Step 3: Walk the smoke checklist** (adapted from spec § 11 under the per-section convention):

1. **Cold open Item Master** — items list populates; Identity embed shows blank fields (selectedItemId is null, getOneOrEmpty returns null shape); no dirty dot anywhere; tabs render with no `●` prefixes.
2. **Click 5G0 row** — Identity embed populates (PartNumber "5G0", ItemType "Finished Good" badge, Description "5G0 Front Cover Assembly", UOM "EA", Unit Weight "3.25", Weight UOM "LB", Default Sub-Lot Qty "24", Parts Per Basket = MaxLotSize value, CountryOfOrigin if set, MaxParts if set, Macola Part # "5G0-FC-001"). No dirty dot. Save/Discard hidden (isDirty=false); Deprecate visible.
3. **Edit Description** — dirty dot appears on the Identity HeaderRow Save/Discard buttons. Tab labels other than the active "Container Config" gray out (Identity dirtiness disables other tabs via the existing `itemMasterTabObjects` rule).
4. **Click Save** — toast "Item updated"; dirty clears; items list refreshes (the Description change is visible in the left panel); tabs re-enable.
5. **Edit Description again, click Discard** — fields revert to last-saved; dirty clears; tabs re-enable.
6. **Edit UnitWeight without WeightUOM** — proc rejects on Save, toast surfaces "WeightUomId is required when UnitWeight is provided."
7. **Edit MaxParts to 0** — proc rejects, toast surfaces "MaxParts must be greater than zero when supplied."
8. **Click +Add Item** — popup opens. (If not, flip BtnAddItem scope to "G" per Step 7 above and re-test.)
9. **Type Part Number "TEST-PH3-001", pick Item Type "Component", UOM "EA", Description "Phase 3 smoke"** → click **Create Item** → toast "Item created" → popup closes → new row appears in left panel (no auto-select).
10. **Click the new row** → Identity embed populates with the new item's values. Deprecate visible.
11. **Click Deprecate** → toast "Item deprecated" → items list refreshes (row disappears) → selectedItemId clears → EmptyState reappears.
12. **Click 5G0 row** (has active dependents — RouteTemplate / Bom) → click Deprecate → toast `error` surfacing "Cannot deprecate: active ... reference this Item." Item stays selected; Identity embed still shows 5G0.
13. **Open AddItem modal, type any character into PartNumber, click ✕** → ConfirmUnsaved popup opens with Save/Discard/Cancel. Click Discard → AddItem popup closes. Click +Add Item again → form is empty again (selected baseline survives because it's the empty-meta shape).
14. **Cross-tab interaction with dirty Identity**: edit Identity (dirty dot shows), try clicking Container Config tab → tab is disabled (visually greyed), click registers nothing. Save → tabs re-enable → Container Config clickable.
15. **Cross-tab interaction with dirty ContainerConfig**: switch to Container Config tab, change ClosureMethod (dirty dot on that tab), try clicking any other tab (including Identity-area, which is in the title bar so not a tab — Identity is always visible) → all 4 other tabs are disabled. Save ContainerConfig → tabs re-enable.
16. **Audit log inspection** (existing Audit page) — `Audit.ConfigLog` shows new rows for: `Item Created`, `Item Updated`, `Item Deprecated` with full OldValue / NewValue / AppUserId.

Steps 1–16 PASS → Phase 3 complete. Any FAIL → halt and triage; flag the failed step in PROJECT_STATUS.md.

- [ ] **Step 4: Update PROJECT_STATUS.md**

Move Phase 3 from "open" to "recently closed" with the commit range. Update the Item Master Phase Status table (Phase 3 → ✓).

- [ ] **Step 5: Commit status + push**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): Item Master Phase 3 landed"
git push origin main
```

---

## Self-Review

**1. Spec coverage:**

| Spec section | Plan task |
|---|---|
| § 1 Goals | All tasks collectively |
| § 2 Architecture Decision A (per-action procs) | Task 8 (entity surface), Task 10 (AddItem.BtnCreate), Task 11 (DetailsHeader replaced — but Save/Deprecate move into Identity embed per §0 reconciliation, see Task 9) |
| § 3 SQL no changes | n/a — no SQL tasks |
| § 4 NQs | Tasks 1–5 |
| § 5.1 Item entity script extensions | Task 8 |
| § 5.2 ItemType entity script | Task 6 |
| § 5.3 Uom entity script | Task 7 |
| § 6.1 AddItem popup | Task 10 |
| § 6.2 Parent ItemMaster | Tasks 9 (Identity embed) + 11 (parent rewire) — note: §6.2's parent-Save/parent-Deprecate handlers move into Task 9 per §0 reconciliation |
| § 6.3 ItemRow no changes | n/a |
| § 7 Mockup-vs-FDS field reconciliation | Task 9 layout (FieldRows 1–4), Task 10 (matching popup fields) |
| § 8 State machine | §0 reconciliation: mode prop dead; visibility driven by `selectedItemId` presence; embedded sections handle their own dirty/save scope |
| § 9 List refresh | Task 11 Step 5 (itemsRefresh handler) |
| § 10 Error handling | Implicit — all paths go through `Common.Ui.notifyResult` which surfaces the proc's `Message` verbatim |
| § 11 Smoke checklist | Task 12 Step 3 (smoke checklist with §0 reconciliation adjustments) |
| § 12 R1-R11 risks | Task 11 Step 7 covers R2 (BtnAddItem scope); R8 Deprecate confirmation explicitly deferred (see Task 9 Step 13 inline note); others either no-op under reconciliation or covered by existing pattern |
| § 13 File deltas | Plan File Structure section |

**2. Placeholder scan:** Every code block contains the actual SQL / JSON / Python. No TBDs. The view-edit boundary callouts (Designer-vs-file) are explicit per task.

**3. Type consistency:** Entity-script function names: `add` / `update` / `deprecate` / `emptyMeta` consistent across Tasks 8, 9, 10. `getForDropdown` consistent for ItemType (Task 6) and Uom (Task 7). NQ identifiers consistent between query.sql and resource.json. Custom-prop names: `editDraft` / `selected` / `isDirty` consistent across ContainerConfig (already shipped) and Identity (Task 9). Message names: `sectionDirtyChanged` / `sectionSaveRequested` / `sectionDiscardRequested` / `itemsRefresh` / `itemDeprecated` consistent across Tasks 9 + 11.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-26-item-master-phase3.md`. Companion spec at `docs/superpowers/specs/2026-05-20-item-master-phase3-design.md`. Convention reconciliation captured in § 0.

Two execution options:

1. **Inline Execution** (recommended for this phase, since the user is co-piloting interactively) — execute tasks here in this session using superpowers:executing-plans with manual smoke at Task 12.
2. **Subagent-Driven** — dispatch a fresh subagent per task. Phase 3 has 12 tasks; Task 9 (Identity view) is the largest and benefits from review between sub-steps.

**Which approach?**
