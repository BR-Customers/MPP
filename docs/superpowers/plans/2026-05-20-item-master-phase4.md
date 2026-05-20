# Item Master Phase 4 — Implementation Plan (ContainerConfig Save)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the parent ItemMaster view's Save button to persist `editDraft.containerConfig` via existing `Parts.ContainerConfig_Create` / `_Update` procs, repair the parent↔child binding contract Phase 2 left inconsistent, and add the deferred `TargetWeight` conditional display.

**Architecture:** Two new Ignition named queries wrap the existing Create/Update procs. The `BlueRidge.Parts.ContainerConfig` entity script gains `add(data)` and `update(data)` mirroring the DefectCode CRUD shape. The ContainerConfig embedded view is rewired so its form fields bidi-bind to `view.params.value.<field>` (an Object param) instead of its own runScript-populated `custom.data`. The parent view passes `view.custom.editDraft.containerConfig` into that param with `bidirectional: true`, extends `itemRowClicked` to fetch + seed both `editDraft.containerConfig` and `selected.containerConfig`, and adds a `handleSave` customMethod with client-side guards that routes Create vs Update based on the presence of `editDraft.containerConfig.Id`.

**Tech Stack:** Ignition Perspective 8.3 (file-based views), Jython 2.7 (script-python modules), SQL Server 2022 (existing procs). No SQL or proc changes — Phase 4 is pure NQ + script + view work.

---

## File Structure

```
ignition/projects/MPP_Config/
├── ignition/
│   ├── named-query/parts/
│   │   ├── ContainerConfig_Create/         [NEW] query.sql + resource.json
│   │   └── ContainerConfig_Update/         [NEW] query.sql + resource.json
│   └── script-python/BlueRidge/Parts/
│       └── ContainerConfig/code.py         [MODIFY] add add() and update()
└── com.inductiveautomation.perspective/views/BlueRidge/
    ├── Components/Parts/ItemMaster/
    │   └── ContainerConfig/view.json       [MODIFY] rewire fields to params.value, add TargetWeight
    └── Views/Parts/ItemMaster/
        └── view.json                       [MODIFY] EmbedContainerConfig binding, itemRowClicked, BtnSave, custom seeds
```

Reference files (read-only) for the executor:
- `sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql` — proc signature truth
- `sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql` — proc signature truth
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Create/resource.json` — NQ resource.json reference for a Create proc
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Update/resource.json` — NQ resource.json reference for an Update proc
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/code.py` — entity-script CRUD shape reference
- `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` — companion design spec

---

### Task 1: Create Named Query `parts/ContainerConfig_Create`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/resource.json`

- [ ] **Step 1: Read the reference NQ resource.json**

```bash
type ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Create\resource.json
```
Use it as the template for the field ordering, scope, version, and sqlType enum. **Do not paraphrase from memory** — match this file's exact JSON shape.

- [ ] **Step 2: Create the query.sql file**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/query.sql`

Content (newline-terminated):

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

- [ ] **Step 3: Create the resource.json**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/resource.json`

Mirror the DefectCode_Create resource.json exactly — `scope:"DG"`, `version:2`, `database:"MPP"`, `type:"Query"`, `cacheEnabled:false`, `lastModification.actor:"claude"`, `lastModificationSignature:""`. Param ordering matches the SQL above. sqlType values:

| param | sqlType |
|---|---|
| `itemId` | `3` (Int8 / BIGINT) |
| `traysPerContainer` | `4` (Int4 / INT) |
| `partsPerTray` | `4` (Int4 / INT) |
| `isSerialized` | `6` (Boolean / BIT) |
| `dunnageCode` | `7` (String / NVARCHAR) |
| `customerCode` | `7` |
| `closureMethod` | `7` |
| `targetWeight` | `8` (Decimal / DECIMAL) |
| `appUserId` | `3` |

If the DefectCode_Create reference uses any sqlType not listed here, prefer the reference's exact enum.

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\ContainerConfig_Create\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```
Expected: `OK`

- [ ] **Step 5: Run gateway scan**

```powershell
.\scan.ps1
```
Expected: JSON response with `scanActive` and a short `lastScanDuration` (~250ms). No errors.

- [ ] **Step 6: Smoke from Designer Script Console**

(Manual / Jacques — captured in the plan so the executor doesn't skip it.) In Designer Script Console:

```python
print system.db.runNamedQuery(
    "parts/ContainerConfig_Create",
    {
        "itemId":            <a real Item Id with NO existing active config>,
        "traysPerContainer": 4,
        "partsPerTray":      12,
        "isSerialized":      True,
        "dunnageCode":       "TEST-DUNNAGE",
        "customerCode":      "TEST-CUST",
        "closureMethod":     "ByCount",
        "targetWeight":      None,
        "appUserId":         2,
    })
```

Expected: a Dataset with one row, columns `Status, Message, NewId`. `Status == 1` and `NewId` a positive BIGINT. If `Status == 0`, read `Message` and fix the cause before proceeding.

If you cannot smoke from Designer right now, mark this step deferred and capture in commit message — but Task 6 below depends on this proc behaving as expected.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/
git commit -m "feat(item-master): NQ parts/ContainerConfig_Create

Wraps Parts.ContainerConfig_Create stored proc. Phase 4 add path."
```

---

### Task 2: Create Named Query `parts/ContainerConfig_Update`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/resource.json`

- [ ] **Step 1: Read the reference NQ resource.json**

```bash
type ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Update\resource.json
```
This Update reference does NOT return `NewId` — only `Status, Message`. Match its shape exactly.

- [ ] **Step 2: Create the query.sql file**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/query.sql`

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

- [ ] **Step 3: Create the resource.json**

Mirror the DefectCode_Update reference exactly. Param ordering matches the SQL above. sqlType table same as Task 1, with `id` replacing `itemId` (still sqlType `3`).

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\ContainerConfig_Update\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Run gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Smoke from Designer Script Console**

```python
print system.db.runNamedQuery(
    "parts/ContainerConfig_Update",
    {
        "id":                <the NewId from Task 1's smoke>,
        "traysPerContainer": 5,
        "partsPerTray":      14,
        "isSerialized":      True,
        "dunnageCode":       "TEST-DUNNAGE-UPDATED",
        "customerCode":      "TEST-CUST",
        "closureMethod":     "ByWeight",
        "targetWeight":      18.75,
        "appUserId":         2,
    })
```

Expected: Dataset row with `Status == 1`. If `Status == 0`, read `Message`.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/
git commit -m "feat(item-master): NQ parts/ContainerConfig_Update

Wraps Parts.ContainerConfig_Update stored proc. Phase 4 update path."
```

---

### Task 3: Extend `BlueRidge.Parts.ContainerConfig` entity script with `add` and `update`

**Files:**
- Modify: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py`

- [ ] **Step 1: Read the current script**

```bash
type ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Parts\ContainerConfig\code.py
```
Confirm Phase 2's surface is just `_u()` + `getByItem()`.

- [ ] **Step 2: Read the DefectCode entity script as the shape reference**

```bash
type ignition\projects\MPP_Config\ignition\script-python\BlueRidge\Quality\DefectCode\code.py
```
Match its `add` / `update` function decoration: `_u(data)`, `Common.Util.log("data=%s" % data)`, `Common.Db.execMutation(...)` with camelCase NQ params, AppUserId pulled from `Common.Util._currentAppUserId()`.

- [ ] **Step 3: Append `add()` and `update()` to ContainerConfig/code.py**

Insert these two functions after the existing `getByItem` definition. Keep the existing `_u` and `getByItem` untouched.

```python
def add(data):
    """Create a new active ContainerConfig for an Item.

    data: {ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
    Returns {Status, Message, NewId}.

    The proc enforces at-most-one-active-config-per-Item via a filtered
    unique index. Attempting to add a second active config for the same
    Item returns Status=0 with a descriptive message.
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
    immutable per the proc -- to re-associate with a different Item,
    deprecate this one and add a new one.

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

- [ ] **Step 4: Run gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Smoke from Designer Script Console**

```python
# Create path
result = BlueRidge.Parts.ContainerConfig.add({
    "ItemId":            <an item with no active config>,
    "TraysPerContainer": 2,
    "PartsPerTray":      24,
    "IsSerialized":      False,
    "ClosureMethod":     "ByCount",
    "TargetWeight":      None,
    "DunnageCode":       None,
    "CustomerCode":      None,
})
print result
# Expected: {Status: True/1, Message: ..., NewId: <int>}

# Update path
result = BlueRidge.Parts.ContainerConfig.update({
    "Id":                <the NewId above>,
    "TraysPerContainer": 3,
    "PartsPerTray":      48,
    "IsSerialized":      True,
    "ClosureMethod":     "ByWeight",
    "TargetWeight":      8.25,
    "DunnageCode":       "DUN-A",
    "CustomerCode":      "CUST-A",
})
print result
# Expected: {Status: True/1, Message: ...}  -- no NewId on Update
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py
git commit -m "feat(item-master): ContainerConfig.add + update entity functions

Phase 4 mutation surface. Mirrors DefectCode CRUD shape. AppUserId
sourced inside the script via _currentAppUserId() -- never passed from
the view."
```

---

### Task 4: Rewire ContainerConfig embedded view to use `params.value` as the data source

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json`

- [ ] **Step 1: Confirm Designer is closed**

Per `feedback_ignition_view_edit_boundary.md`, file edits to existing views are safe only when Designer is not running. If Designer is open with the parent ItemMaster view loaded, its in-memory cache will fight the disk edit.

- [ ] **Step 2: Change `params.value` default + remove `custom.data`**

Open `ContainerConfig/view.json`. Replace the top-level `custom` and `params`/`propConfig` blocks:

**Before (lines 1–18):**
```json
{
  "custom": {
    "data": {}
  },
  "params": {
    "value": 0
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"},
    "custom.data": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "runScript(\"BlueRidge.Parts.ContainerConfig.getByItem\", 0, {view.params.value})"
        }
      }
    }
  },
```

**After:**
```json
{
  "custom": {},
  "params": {
    "value": {
      "Id":                null,
      "ItemId":            null,
      "TraysPerContainer": null,
      "PartsPerTray":      null,
      "IsSerialized":      false,
      "ClosureMethod":     null,
      "TargetWeight":      null,
      "DunnageCode":       null,
      "CustomerCode":      null
    }
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"}
  },
```

- [ ] **Step 3: Rebind each form field's path from `view.custom.data.<field>` → `view.params.value.<field>`**

Six bindings to change. Each is a six-character substring replace.

| Field | Old path | New path |
|---|---|---|
| InputTraysPerContainer | `view.custom.data.TraysPerContainer` | `view.params.value.TraysPerContainer` |
| InputPartsPerTray      | `view.custom.data.PartsPerTray`      | `view.params.value.PartsPerTray` |
| DropdownIsSerialized   | `view.custom.data.IsSerialized`      | `view.params.value.IsSerialized` |
| DropdownClosureMethod  | `view.custom.data.ClosureMethod`     | `view.params.value.ClosureMethod` |
| InputDunnageCode       | `view.custom.data.DunnageCode`       | `view.params.value.DunnageCode` |
| InputCustomerCode      | `view.custom.data.CustomerCode`      | `view.params.value.CustomerCode` |

Use the Edit tool with replace_all=true on the literal substring `view.custom.data.` → `view.params.value.` — all six occurrences should switch in one call. Bidirectional flag stays true.

- [ ] **Step 4: Add the new `TargetWeight` field with conditional display**

Insert this field-container into `FieldRow2`'s `children` array, between `FieldClosureMethod` and `FieldDunnageCode`:

```json
{
  "type": "ia.container.flex",
  "meta": {"name": "FieldTargetWeight"},
  "position": {"basis": "auto"},
  "propConfig": {
    "position.display": {
      "binding": {
        "type": "expr",
        "config": {"expression": "{view.params.value.ClosureMethod} = \"ByWeight\""}
      }
    }
  },
  "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
  "children": [
    {
      "type": "ia.display.label",
      "meta": {"name": "LabelTargetWeight"},
      "position": {"basis": "auto"},
      "props": {"text": "Target Weight", "style": {"classes": "field-label"}}
    },
    {
      "type": "ia.input.text-field",
      "meta": {"name": "InputTargetWeight"},
      "position": {"basis": "auto"},
      "propConfig": {
        "props.text": {
          "binding": {
            "type": "property",
            "config": {"bidirectional": true, "path": "view.params.value.TargetWeight"}
          }
        }
      },
      "props": {"style": {"classes": "search-input", "width": "100px"}}
    }
  ]
}
```

- [ ] **Step 5: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\ItemMaster\ContainerConfig\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 6: Run gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/
git commit -m "refactor(item-master): ContainerConfig embed binds to params.value

Replace child-owned custom.data + runScript binding with bidirectional
bindings on params.value.* per the Phase 1/2 spec intent. Parent now
owns editDraft.containerConfig and pushes it down via Object param
(rewired in the next commit).

Adds TargetWeight field with position.display gated on
ClosureMethod == 'ByWeight'."
```

---

### Task 5: Rewire parent EmbedContainerConfig binding + extend `itemRowClicked` + add containerConfig to initial custom seeds

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json`

- [ ] **Step 1: Read the current EmbedContainerConfig binding**

Located in the view's first tab Embedded View (`meta.name = "ContainerConfig"`, around line 950–968 per the current file). Verify before editing.

- [ ] **Step 2: Change EmbedContainerConfig `props.params.value` binding**

**Before:**
```json
"meta": {"name": "ContainerConfig"},
"propConfig": {
  "props.params.value": {
    "binding": {
      "type": "property",
      "config": {"path": "view.custom.editDraft.meta.Id"}
    }
  }
},
"props": {
  "params": {"value": 0},
  "path": "BlueRidge/Components/Parts/ItemMaster/ContainerConfig"
},
"type": "ia.display.view"
```

**After:**
```json
"meta": {"name": "ContainerConfig"},
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
},
"props": {
  "params": {"value": {}},
  "path": "BlueRidge/Components/Parts/ItemMaster/ContainerConfig"
},
"type": "ia.display.view"
```

Leave the four other tab embeds (Routes, Boms, QualitySpecs, Eligibility) bound to `view.custom.editDraft.meta.Id` unchanged — they don't have bidi slices yet.

- [ ] **Step 3: Extend the `itemRowClicked` message handler**

Current handler (in `root.scripts.messageHandlers`, the `itemRowClicked` entry):

```python
clickedId = payload.get('id') if payload else None
if clickedId is None:
    return
itemMeta = BlueRidge.Parts.Item.getOne(clickedId)
if itemMeta is None:
    BlueRidge.Common.Notify.toast('Item not found', 'Item id ' + str(clickedId) + ' no longer exists.', 'warning')
    return
self.view.custom.selected  = {'meta': dict(itemMeta)}
self.view.custom.editDraft = {'meta': dict(itemMeta)}
self.view.custom.mode = 'update'
```

Replace its script with (note: this is one string in the JSON, with `\n` and `\t` escapes; write it whole):

```python
clickedId = payload.get('id') if payload else None
if clickedId is None:
    return
itemMeta = BlueRidge.Parts.Item.getOne(clickedId)
if itemMeta is None:
    BlueRidge.Common.Notify.toast('Item not found', 'Item id ' + str(clickedId) + ' no longer exists.', 'warning')
    return
ccRow = BlueRidge.Parts.ContainerConfig.getByItem(clickedId) or {}
cc = {
    'Id':                ccRow.get('Id'),
    'ItemId':            clickedId,
    'TraysPerContainer': ccRow.get('TraysPerContainer'),
    'PartsPerTray':      ccRow.get('PartsPerTray'),
    'IsSerialized':      bool(ccRow.get('IsSerialized', False)),
    'ClosureMethod':     ccRow.get('ClosureMethod'),
    'TargetWeight':      ccRow.get('TargetWeight'),
    'DunnageCode':       ccRow.get('DunnageCode'),
    'CustomerCode':      ccRow.get('CustomerCode'),
}
self.view.custom.selected  = {'meta': dict(itemMeta), 'containerConfig': dict(cc)}
self.view.custom.editDraft = {'meta': dict(itemMeta), 'containerConfig': dict(cc)}
self.view.custom.mode = 'update'
```

- [ ] **Step 4: Update the initial `custom.editDraft` and `custom.selected` seeds**

The parent view's top-level `custom` block currently has `editDraft: {meta: {}}` and `selected: {meta: {}}`. Extend each to include the empty `containerConfig` slice so the binding has a valid path before the first item click:

**Before:**
```json
"editDraft": {"meta": {}},
"selected":  {"meta": {}}
```

**After:**
```json
"editDraft": {
  "meta": {},
  "containerConfig": {
    "Id":                null,
    "ItemId":            null,
    "TraysPerContainer": null,
    "PartsPerTray":      null,
    "IsSerialized":      false,
    "ClosureMethod":     null,
    "TargetWeight":      null,
    "DunnageCode":       null,
    "CustomerCode":      null
  }
},
"selected": {
  "meta": {},
  "containerConfig": {
    "Id":                null,
    "ItemId":            null,
    "TraysPerContainer": null,
    "PartsPerTray":      null,
    "IsSerialized":      false,
    "ClosureMethod":     null,
    "TargetWeight":      null,
    "DunnageCode":       null,
    "CustomerCode":      null
  }
}
```

Both seeds are deep-equal, so the dirty indicator stays clear on cold open.

- [ ] **Step 5: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Views\Parts\ItemMaster\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 6: Run gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): wire editDraft.containerConfig via bidi embed

Parent EmbedContainerConfig now bidi-binds editDraft.containerConfig
into the child's params.value. itemRowClicked extends to fetch
ContainerConfig (or empty defaults if no active config exists) and
seed both editDraft and selected so the dirty indicator works
symmetrically. Initial custom seeds also include the containerConfig
slice so the binding has a valid path before the first item click."
```

---

### Task 6: Add `handleSave` customMethod + wire BtnSave's onActionPerformed

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json`

- [ ] **Step 1: Locate `root.scripts.customMethods` in the parent view**

Find the existing `customMethods` array (sibling of `messageHandlers` under `root.scripts`). If empty, you'll add the first entry. If it already has methods, append.

- [ ] **Step 2: Add `handleSave` to `customMethods`**

The new entry (JSON shape — note `params` MUST NOT include `"self"` per `feedback_ignition_view_customMethods_scope.md`; Ignition auto-prepends it):

```json
{
  "name": "handleSave",
  "params": [],
  "script": "<see below>"
}
```

The `script` value (one JSON string, with `\t` and `\n` escapes preserved when serializing):

```python
draft  = self.view.custom.editDraft or {}
meta   = draft.get('meta') or {}
cc     = dict(draft.get('containerConfig') or {})
itemId = meta.get('Id')

if not itemId:
    BlueRidge.Common.Notify.toast('No item selected', 'Select an item before saving container configuration.', 'warning')
    return

trays        = cc.get('TraysPerContainer')
partsPerTray = cc.get('PartsPerTray')
if trays is None or trays <= 0:
    BlueRidge.Common.Notify.toast('Trays per Container required', 'Enter a positive number of trays per container.', 'warning')
    return
if partsPerTray is None or partsPerTray <= 0:
    BlueRidge.Common.Notify.toast('Parts per Tray required', 'Enter a positive number of parts per tray.', 'warning')
    return
if cc.get('ClosureMethod') == 'ByWeight':
    tw = cc.get('TargetWeight')
    if tw is None or tw <= 0:
        BlueRidge.Common.Notify.toast('Target Weight required', 'ByWeight closure requires a positive target weight.', 'warning')
        return

cc['ItemId'] = itemId
if cc.get('Id'):
    result       = BlueRidge.Parts.ContainerConfig.update(cc)
    successTitle = 'Container config updated'
else:
    result       = BlueRidge.Parts.ContainerConfig.add(cc)
    successTitle = 'Container config saved'

BlueRidge.Common.Ui.notifyResult(result, successTitle)

if result and result.get('Status'):
    refreshed = BlueRidge.Parts.ContainerConfig.getByItem(itemId) or {}
    newCc = {
        'Id':                refreshed.get('Id'),
        'ItemId':            itemId,
        'TraysPerContainer': refreshed.get('TraysPerContainer'),
        'PartsPerTray':      refreshed.get('PartsPerTray'),
        'IsSerialized':      bool(refreshed.get('IsSerialized', False)),
        'ClosureMethod':     refreshed.get('ClosureMethod'),
        'TargetWeight':      refreshed.get('TargetWeight'),
        'DunnageCode':       refreshed.get('DunnageCode'),
        'CustomerCode':      refreshed.get('CustomerCode'),
    }
    nextDraft = dict(self.view.custom.editDraft)
    nextDraft['containerConfig'] = dict(newCc)
    self.view.custom.editDraft = nextDraft
    nextSelected = dict(self.view.custom.selected)
    nextSelected['containerConfig'] = dict(newCc)
    self.view.custom.selected = nextSelected
```

- [ ] **Step 3: Rewire BtnSave's onActionPerformed**

Find the `BtnSave` component in the view (its current `onActionPerformed` toasts "Not wired yet — Item save lands in Phase 3"). Replace its script:

**Before:**
```python
BlueRidge.Common.Notify.toast('Not wired yet', 'Item save lands in Phase 3.', 'info', 5)
```

**After:**
```python
self.view.rootContainer.handleSave()
```

Keep the event's `scope: "G"` if present (or set to `"G"`) — per `feedback_ignition_popup_open_scope.md`, popup-open events sometimes need `G`; for a method call into the same view this is also safer than `C`.

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Views\Parts\ItemMaster\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Run gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): wire Save button to ContainerConfig add/update

handleSave customMethod routes to ContainerConfig.update when
editDraft.containerConfig.Id exists, else ContainerConfig.add.
Client-side guards on TraysPerContainer, PartsPerTray, and
TargetWeight (when ByWeight). On success: re-fetches via getByItem
and reassigns editDraft + selected via parent-dict clones so the
bidi binding re-fires on the child."
```

---

### Task 7: Designer smoke + Phase 4 close-out

This task is for Jacques, not the executor.

- [ ] **Step 1: Pull latest main**

```bash
git pull --ff-only origin main
```

Confirm Tasks 1–6 are all present.

- [ ] **Step 2: Run gateway scan one more time**

```powershell
.\scan.ps1
```

- [ ] **Step 3: Smoke per spec §8**

Walk the 10-step checklist in `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` §8.

The critical R1 step is #4 (ClosureMethod=ByCount → ByWeight). If it fails (dirty indicator doesn't light OR `editDraft.containerConfig.ClosureMethod` doesn't update in the property browser), STOP, open a Phase 4 follow-up, and follow the §7.1 fallback design.

- [ ] **Step 4: Update PROJECT_STATUS.md**

Promote the "Item Master Phase 2 read paths landed; R1 bidi-embed smoke pending" note to "Phase 4 ContainerConfig save landed + R1 verified pass". If R1 failed, note the fallback work as a new open block.

- [ ] **Step 5: Commit status update + push**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): Item Master Phase 4 ContainerConfig save landed"
git push origin main
```

---

## Self-Review

- **Spec coverage:** All spec sections map to tasks. §3.2 file deltas → Tasks 1–6. §3.3 data shapes → Task 5 (seeds) + Task 3 (entity script). §3.4 itemRowClicked → Task 5. §3.5 embedded view rewiring → Task 4. §3.6 parent embed rewiring → Task 5. §3.7 Save handler → Task 6. §3.8 entity script additions → Task 3. §4 NQs → Tasks 1, 2. §7 risks + §7.1 fallback → noted in Task 7 step 3. §8 smoke → Task 7.
- **Placeholder scan:** No `TBD`, no "add appropriate handling", no "fill in details". Every step has the literal SQL / JSON / Python.
- **Type consistency:** All field names PascalCase (matches DB columns: `TraysPerContainer`, `ClosureMethod`, `TargetWeight`, etc.) in dicts; NQ param keys camelCase. `_currentAppUserId` always called inside the entity script, never passed from the view. The R1-gated dependency between Tasks 4/5 and Task 7's smoke is called out.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-20-item-master-phase4.md`. Companion spec at `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks. Phase 4 has 7 tasks; each is a self-contained file edit + scan + commit, ideal for the subagent pattern.

2. **Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints. Faster if Jacques wants Phase 4 landed in this session.

If a worktree is desired (matching the agent-X convention used for Routes / BOMs design work), create it before Task 1:

```powershell
git worktree add -b item-master-phase4 ..\mpp-worktrees\agent-A-phase4 main
```

…then run all tasks inside that worktree, and merge to main at the end.

**Which approach?**
