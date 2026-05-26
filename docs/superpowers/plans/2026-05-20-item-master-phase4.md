# Item Master Phase 4 — Implementation Plan (ContainerConfig Section)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Read `project_mpp_item_master_pattern` memory before starting** — it codifies the per-section ownership pattern this plan implements.

**Goal:** Retrofit the ContainerConfig tab to the per-section ownership pattern, wire its own Save + Discard via existing `Parts.ContainerConfig_Create` / `_Update` procs, add the deferred `TargetWeight` conditional field, AND lay down the parent's section-dirty + switch-gate infrastructure (Phase 4 is first to ship under the convention, so it builds the infra; later phases inherit it).

**Architecture:** ContainerConfig embed owns its own `view.custom.selected` and `view.custom.editDraft` LOCALLY; receives only `params.value: itemId` (BIGINT, input-only); fetches its own data on item-id change; has its own Save/Discard buttons; broadcasts dirty state via `sectionDirtyChanged` page-scoped message. Parent maintains `view.custom.sectionDirty` flag map + `pendingSwitch` staging area + ConfirmUnsaved gate on tab clicks and item-row clicks. NO bundled editDraft on parent. NO bidirectional Object-param. Pattern reference: `project_mpp_item_master_pattern` memory.

**Tech Stack:** Ignition Perspective 8.3 (file-based views), Jython 2.7, SQL Server 2022 (existing procs). No SQL changes — proc + test coverage already exist.

---

## File Structure

```
ignition/projects/MPP_Config/
├── ignition/
│   ├── named-query/parts/
│   │   ├── ContainerConfig_Create/         [NEW] query.sql + resource.json
│   │   └── ContainerConfig_Update/         [NEW] query.sql + resource.json
│   └── script-python/BlueRidge/Parts/
│       └── ContainerConfig/code.py         [MODIFY] add add() + update()
└── com.inductiveautomation.perspective/views/BlueRidge/
    ├── Components/Parts/ItemMaster/
    │   └── ContainerConfig/view.json       [REWRITE] full retrofit to per-section pattern
    └── Views/Parts/ItemMaster/
        └── view.json                       [HEAVY MODIFY] demolish old bundled editDraft/selected;
                                                         add selectedItemId + sectionDirty + pendingSwitch;
                                                         rewire all 5 tab embeds to selectedItemId;
                                                         add gate customMethods + message handlers;
                                                         add per-tab dirty dot indicators
```

Reference files (read-only):
- `sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql` — proc signature truth
- `sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql` — proc signature truth
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Create/resource.json` — NQ resource.json reference (Create with NewId)
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Update/resource.json` — NQ resource.json reference (Update, no NewId)
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/code.py` — entity script CRUD shape reference
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfirmUnsaved/view.json` — the popup reused for the switch gate
- `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` — companion design spec

---

### Task 1: Create Named Query `parts/ContainerConfig_Create`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/resource.json`

- [ ] **Step 1: Read the DefectCode_Create reference resource.json**

```powershell
Get-Content ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Create\resource.json
```
Match the exact JSON field order, top-level `attributes` shape, scope/version/database keys.

- [ ] **Step 2: Create the query.sql**

Path: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Create/query.sql`

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

- [ ] **Step 3: Create resource.json**

Mirror DefectCode_Create shape. Params + sqlType:

| param | sqlType |
|---|---|
| `itemId` | `3` (Int8 / BIGINT) |
| `traysPerContainer` | `4` (Int4 / INT) |
| `partsPerTray` | `4` |
| `isSerialized` | `6` (Boolean / BIT) |
| `dunnageCode` | `7` (String / NVARCHAR) |
| `customerCode` | `7` |
| `closureMethod` | `7` |
| `targetWeight` | `8` (Decimal / DECIMAL) |
| `appUserId` | `3` |

If the reference's existing INT or DECIMAL params disagree with these guesses, prefer the reference's enums.

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\ContainerConfig_Create\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Smoke from Designer Script Console** (manual; capture in commit if deferred)

```python
print system.db.runNamedQuery(
    "parts/ContainerConfig_Create",
    {
        "itemId":            <a real Item with NO existing active config>,
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
Expected: Dataset row with `Status=1`, `Message`, `NewId` a positive BIGINT.

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

- [ ] **Step 1: Read DefectCode_Update reference**

```powershell
Get-Content ignition\projects\MPP_Config\ignition\named-query\quality\DefectCode_Update\resource.json
```
Update procs return `Status, Message` only — no `NewId`.

- [ ] **Step 2: Create query.sql**

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

- [ ] **Step 3: Create resource.json**

Mirror DefectCode_Update. Same sqlType table as Task 1 with `id` (sqlType `3`) replacing `itemId`.

- [ ] **Step 4: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\ignition\named-query\parts\ContainerConfig_Update\resource.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 5: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 6: Smoke from Designer Script Console**

```python
print system.db.runNamedQuery(
    "parts/ContainerConfig_Update",
    {
        "id":                <NewId from Task 1>,
        "traysPerContainer": 5,
        "partsPerTray":      14,
        "isSerialized":      True,
        "dunnageCode":       "TEST-UPDATED",
        "customerCode":      "TEST-CUST",
        "closureMethod":     "ByWeight",
        "targetWeight":      18.75,
        "appUserId":         2,
    })
```

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_Update/
git commit -m "feat(item-master): NQ parts/ContainerConfig_Update

Wraps Parts.ContainerConfig_Update stored proc. Phase 4 update path."
```

---

### Task 3: Extend `BlueRidge.Parts.ContainerConfig` entity script with `add` + `update`

**Files:**
- Modify: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py`

- [ ] **Step 1: Read current script**

Confirm Phase 2 surface is just `_u` + `getByItem`.

- [ ] **Step 2: Read DefectCode entity script** for the CRUD shape reference.

- [ ] **Step 3: Append two functions to ContainerConfig/code.py** (after `getByItem`):

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

- [ ] **Step 4: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Smoke from Script Console**

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
print result   # Expected: {Status: True/1, Message: ..., NewId: <int>}

# Update path
result = BlueRidge.Parts.ContainerConfig.update({
    "Id":                <NewId above>,
    "TraysPerContainer": 3,
    "PartsPerTray":      48,
    "IsSerialized":      True,
    "ClosureMethod":     "ByWeight",
    "TargetWeight":      8.25,
    "DunnageCode":       "DUN-A",
    "CustomerCode":      "CUST-A",
})
print result   # Expected: {Status: True/1, Message: ...}
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

### Task 4: Rewrite ContainerConfig embed for per-section ownership

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json`

Confirm Designer is closed before file edits.

- [ ] **Step 1: Read current view.json** to capture the existing field layout (TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, DunnageCode, CustomerCode). These get preserved with new bindings.

- [ ] **Step 2: Replace the top-level `custom`, `params`, `propConfig` blocks**

The entire file is rewritten in this task because the changes touch every layer. Use Write (not Edit) to replace the file.

Top-level structure:

```json
{
  "custom": {
    "selected": {
      "Id":                null,
      "ItemId":            null,
      "TraysPerContainer": null,
      "PartsPerTray":      null,
      "IsSerialized":      false,
      "ClosureMethod":     null,
      "TargetWeight":      null,
      "DunnageCode":       null,
      "CustomerCode":      null
    },
    "editDraft": {
      "Id":                null,
      "ItemId":            null,
      "TraysPerContainer": null,
      "PartsPerTray":      null,
      "IsSerialized":      false,
      "ClosureMethod":     null,
      "TargetWeight":      null,
      "DunnageCode":       null,
      "CustomerCode":      null
    },
    "isDirty": false
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
        "script": "\tsystem.perspective.sendMessage(\"sectionDirtyChanged\", payload={\"section\": \"containerConfig\", \"isDirty\": bool(currentValue.value)}, scope=\"page\")"
      }
    }
  },
  "props": {
    "defaultSize": { "width": 800, "height": 220 }
  },
  "root": { ... see Step 3 ... }
}
```

- [ ] **Step 3: Write the `root` block** — flex column with HeaderRow + FieldRow1 + FieldRow2.

HeaderRow holds the panel title + Save + Discard buttons:

```json
{
  "type": "ia.container.flex",
  "meta": {"name": "HeaderRow"},
  "position": {"basis": "auto"},
  "props": {"direction": "row", "alignItems": "center", "style": {"gap": "8px", "marginBottom": "4px"}},
  "children": [
    {
      "type": "ia.display.label",
      "meta": {"name": "PanelHeader"},
      "position": {"basis": "auto"},
      "props": {
        "text": "Container Configuration",
        "style": {"fontSize": "13px", "fontWeight": "600"}
      }
    },
    {
      "type": "ia.display.label",
      "meta": {"name": "Spacer"},
      "position": {"grow": 1},
      "props": {"text": ""}
    },
    {
      "type": "ia.input.button",
      "meta": {"name": "BtnDiscard"},
      "position": {"basis": "auto"},
      "propConfig": {
        "meta.visible": {
          "binding": {"type": "property", "config": {"path": "view.custom.isDirty"}}
        }
      },
      "props": {"text": "Discard", "style": {"classes": "btn btn-sm"}},
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script",
            "scope": "G",
            "config": {"script": "\tself.view.rootContainer.handleDiscard()"}
          }
        }
      }
    },
    {
      "type": "ia.input.button",
      "meta": {"name": "BtnSave"},
      "position": {"basis": "auto"},
      "propConfig": {
        "meta.visible": {
          "binding": {"type": "property", "config": {"path": "view.custom.isDirty"}}
        }
      },
      "props": {"text": "Save", "style": {"classes": "btn btn-primary btn-sm"}},
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script",
            "scope": "G",
            "config": {"script": "\tself.view.rootContainer.handleSave()"}
          }
        }
      }
    }
  ]
}
```

FieldRow1 — three fields, all bidi-bound to `view.custom.editDraft.<field>`:

```json
{
  "type": "ia.container.flex",
  "meta": {"name": "FieldRow1"},
  "position": {"basis": "auto"},
  "props": {"direction": "row", "style": {"classes": "field-row", "gap": "12px"}},
  "children": [
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldTraysPerContainer"},
      "position": {"basis": "auto"},
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Trays Per Container", "style": {"classes": "field-label"}}},
        {"type": "ia.input.text-field", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.text": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.TraysPerContainer"}}}},
         "props": {"style": {"classes": "search-input", "width": "80px"}}}
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldPartsPerTray"},
      "position": {"basis": "auto"},
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Parts Per Tray", "style": {"classes": "field-label"}}},
        {"type": "ia.input.text-field", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.text": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.PartsPerTray"}}}},
         "props": {"style": {"classes": "search-input", "width": "80px"}}}
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldIsSerialized"},
      "position": {"basis": "auto"},
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Serialized", "style": {"classes": "field-label"}}},
        {"type": "ia.input.dropdown", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.value": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.IsSerialized"}}}},
         "props": {
           "options": [{"label": "Yes", "value": true}, {"label": "No", "value": false}],
           "style": {"classes": "select"}
         }}
      ]
    }
  ]
}
```

FieldRow2 — ClosureMethod, TargetWeight (conditional), DunnageCode, CustomerCode:

```json
{
  "type": "ia.container.flex",
  "meta": {"name": "FieldRow2"},
  "position": {"basis": "auto"},
  "props": {"direction": "row", "style": {"classes": "field-row", "gap": "12px"}},
  "children": [
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldClosureMethod"},
      "position": {"basis": "auto"},
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Closure Method", "style": {"classes": "field-label"}}},
        {"type": "ia.input.dropdown", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.value": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.ClosureMethod"}}}},
         "props": {
           "options": [
             {"label": "ByCount",  "value": "ByCount"},
             {"label": "ByWeight", "value": "ByWeight"},
             {"label": "ByVision", "value": "ByVision"}
           ],
           "style": {"classes": "select"}
         }}
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldTargetWeight"},
      "position": {"basis": "auto"},
      "propConfig": {
        "position.display": {
          "binding": {"type": "expr",
            "config": {"expression": "{view.custom.editDraft.ClosureMethod} = \"ByWeight\""}}
        }
      },
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Target Weight", "style": {"classes": "field-label"}}},
        {"type": "ia.input.text-field", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.text": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.TargetWeight"}}}},
         "props": {"style": {"classes": "search-input", "width": "100px"}}}
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldDunnageCode"},
      "position": {"basis": "auto"},
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Dunnage Code", "style": {"classes": "field-label"}}},
        {"type": "ia.input.text-field", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.text": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.DunnageCode"}}}},
         "props": {"style": {"classes": "search-input", "width": "120px"}}}
      ]
    },
    {
      "type": "ia.container.flex",
      "meta": {"name": "FieldCustomerCode"},
      "position": {"basis": "auto"},
      "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
      "children": [
        {"type": "ia.display.label", "meta": {"name": "Label"}, "position": {"basis": "auto"},
         "props": {"text": "Customer Code", "style": {"classes": "field-label"}}},
        {"type": "ia.input.text-field", "meta": {"name": "Input"}, "position": {"basis": "auto"},
         "propConfig": {"props.text": {"binding": {"type": "property",
           "config": {"bidirectional": true, "path": "view.custom.editDraft.CustomerCode"}}}},
         "props": {"style": {"classes": "search-input", "width": "140px"}}}
      ]
    }
  ]
}
```

The root container wraps these three rows with `direction: column`, `style.classes: detail-panel`, `padding: 12px 14px`, `gap: 10px` — matching the Phase 2 file's outer container shape.

- [ ] **Step 4: Add `root.scripts.customMethods` and `messageHandlers`**

Three customMethods + two message handlers under `root.scripts`. Each entry's `params` array MUST NOT include `"self"` (Ignition auto-prepends per the customMethods-scope memory).

```json
"scripts": {
  "customMethods": [
    {
      "name": "load",
      "params": [],
      "script": "<load script — see below>"
    },
    {
      "name": "handleSave",
      "params": [],
      "script": "<handleSave script — see below>"
    },
    {
      "name": "handleDiscard",
      "params": [],
      "script": "<handleDiscard script — see below>"
    }
  ],
  "messageHandlers": [
    {
      "messageType": "sectionSaveRequested",
      "pageScope": true,
      "sessionScope": false,
      "viewScope": false,
      "script": "\tif payload and payload.get(\"section\") == \"containerConfig\":\n\t\tself.rootContainer.handleSave()"
    },
    {
      "messageType": "sectionDiscardRequested",
      "pageScope": true,
      "sessionScope": false,
      "viewScope": false,
      "script": "\tif payload and payload.get(\"section\") == \"containerConfig\":\n\t\tself.rootContainer.handleDiscard()"
    }
  ]
}
```

`load` script (one JSON string with `\n` and `\t` escapes preserved):

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

`handleSave`:

```python
draft = self.view.custom.editDraft or {}
itemId = self.view.params.value
if not itemId:
    BlueRidge.Common.Notify.toast("No item selected", "Select an item before saving container configuration.", "warning")
    return
trays = draft.get("TraysPerContainer")
partsPerTray = draft.get("PartsPerTray")
if trays is None or trays <= 0:
    BlueRidge.Common.Notify.toast("Trays per Container required", "Enter a positive number of trays per container.", "warning")
    return
if partsPerTray is None or partsPerTray <= 0:
    BlueRidge.Common.Notify.toast("Parts per Tray required", "Enter a positive number of parts per tray.", "warning")
    return
if draft.get("ClosureMethod") == "ByWeight":
    tw = draft.get("TargetWeight")
    if tw is None or tw <= 0:
        BlueRidge.Common.Notify.toast("Target Weight required", "ByWeight closure requires a positive target weight.", "warning")
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
    self.load()
```

`handleDiscard`:

```python
self.view.custom.editDraft = dict(self.view.custom.selected)
```

- [ ] **Step 5: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Components\Parts\ItemMaster\ContainerConfig\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 6: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/
git commit -m "refactor(item-master): ContainerConfig embed owns its own state

Per-section ownership pattern (per project_mpp_item_master_pattern
memory). Embed holds local selected + editDraft, fetches its own
data on params.value change, has its own Save + Discard buttons,
broadcasts sectionDirtyChanged page-scoped on dirty transitions,
listens for sectionSaveRequested + sectionDiscardRequested from
parent. Adds TargetWeight field with position.display gated on
ClosureMethod == 'ByWeight'.

No more bidi Object-param. params.value is now a plain BIGINT itemId."
```

---

### Task 5: Add parent-side gate infrastructure to ItemMaster view

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json`

This is the largest task — it touches the parent view's custom props, all five tab-embed bindings, message handlers, and customMethods. Confirm Designer is closed.

- [ ] **Step 1: Replace the top-level `custom` block**

Demolish the old `editDraft`, `selected`, `mode` properties (which were never properly populated for ContainerConfig anyway). Add the new gate-infrastructure props.

**Before:**

```json
"custom": {
  "activeTab": "containerConfig",
  "editDraft": { ... },
  "selected":  { ... },
  "mode": "...",
  "items": [],
  "itemTypes": [...],
  "uoms": [...],
  "search": "",
  "typeFilter": "All Types"
}
```

**After:**

```json
"custom": {
  "selectedItemId": null,
  "activeTab":      "containerConfig",
  "sectionDirty": {
    "identity":        false,
    "containerConfig": false,
    "routes":          false,
    "boms":            false,
    "qualitySpecs":    false,
    "eligibility":     false
  },
  "pendingSwitch": null,
  "items":      [],
  "itemTypes":  [...],
  "uoms":       [...],
  "search":     "",
  "typeFilter": "All Types"
}
```

Preserve `items`, `itemTypes`, `uoms`, `search`, `typeFilter` blocks verbatim — they're Phase 2 read-path infrastructure that still applies.

- [ ] **Step 2: Rewire all five tab embeds' `params.value` to `view.custom.selectedItemId`**

Each of the five Embedded View components (ContainerConfig, Routes, Boms, QualitySpecs, Eligibility) currently has:

```json
"propConfig": {
  "props.params.value": {
    "binding": {"type": "property", "config": {"path": "view.custom.editDraft.meta.Id"}}
  }
}
```

Replace ALL FIVE with:

```json
"propConfig": {
  "props.params.value": {
    "binding": {"type": "property", "config": {"path": "view.custom.selectedItemId"}}
  }
}
```

(No `bidirectional: true` — input-only.)

- [ ] **Step 3: Remove identity-field bindings that referenced the deleted editDraft.meta**

The current parent view has Identity-section input bindings like `view.custom.editDraft.meta.PartNumber`. Those paths no longer exist. Phase 3 will carve Identity into its own embed. For Phase 4, the Identity bindings become DEAD until Phase 3 reconstructs them.

**Two options:** (pick one)

  (a) Remove the Identity input bindings entirely — fields render their `props.text`/`props.value` literal defaults (likely empty strings / nulls). Header shows blank until Phase 3.
  (b) Hide the Identity input section behind `meta.visible: false` so it doesn't render at all in Phase 4. Header area shows the title row + Add/Save/Deprecate buttons only.

Option (b) is cleaner — easier to inspect the view in Designer without "broken" fields. Recommend (b). Implementation: for each Identity-field container under the SummaryRow / Identity panel, set `meta.visible: false`. The fields remain in the JSON for Phase 3 to re-enable.

- [ ] **Step 4: Add per-tab dirty-dot indicators on TabContainer**

The existing TabContainer (around line 1062 of the current view) has `props.tabs: ["Container Config", "Routes", "Boms", "Quality Specs", "Eligibility"]`. Ignition's TabContainer doesn't natively support custom tab labels, but it does support binding the entire `tabs` array. Replace the static array with an expression-bound one that injects the dot:

```json
"propConfig": {
  "props.tabs": {
    "binding": {
      "type": "expr",
      "config": {
        "expression": "[\nif({view.custom.sectionDirty.containerConfig}, '● Container Config', 'Container Config'),\nif({view.custom.sectionDirty.routes},          '● Routes',          'Routes'),\nif({view.custom.sectionDirty.boms},            '● Boms',            'Boms'),\nif({view.custom.sectionDirty.qualitySpecs},    '● Quality Specs',   'Quality Specs'),\nif({view.custom.sectionDirty.eligibility},     '● Eligibility',     'Eligibility')\n]"
      }
    }
  }
}
```

(`●` is the same `●` character used elsewhere in the project.)

- [ ] **Step 5: Wire TabContainer's tab-change gate**

The TabContainer's `props.currentTabIndex` (or the equivalent in 8.3 — verify the prop name in Designer) currently has no onChange. Add a tab-change interceptor: when the user clicks a different tab, check the CURRENT section's dirty flag. If dirty, stage and open the popup instead of changing the tab.

This requires the TabContainer's `currentTabIndex` to bidi-bind to `view.custom.activeTabIndex` (a new custom prop derived from `activeTab`). On change of `activeTabIndex`, run an interceptor in onChange.

The cleaner pattern in Ignition Perspective is to bind `currentTabIndex` to a custom prop `view.custom.activeTabIndex` bidirectionally AND add an onChange handler on `activeTabIndex` that:

```python
# onChange of view.custom.activeTabIndex
prev = previousValue.value
curr = currentValue.value
sectionKeys = ["containerConfig", "routes", "boms", "qualitySpecs", "eligibility"]
if prev is None or curr is None or prev == curr:
    return
currentSection = sectionKeys[prev] if prev < len(sectionKeys) else None
if currentSection and self.view.custom.sectionDirty.get(currentSection, False):
    # Stage the pending switch, revert the tab, open popup.
    self.view.custom.pendingSwitch = {"kind": "tab", "to": curr}
    self.view.custom.activeTabIndex = prev  # revert; Ignition reflects the change
    self.view.rootContainer.openConfirmUnsaved(currentSection)
else:
    self.view.custom.activeTab = sectionKeys[curr] if curr < len(sectionKeys) else None
```

Add `view.custom.activeTabIndex: 0` to the `custom` block in Step 1.

- [ ] **Step 6: Add the three new customMethods on `root.scripts.customMethods`**

`openConfirmUnsaved`:

```python
# params: [sectionKey]
titles = {
    "identity":        "Identity",
    "containerConfig": "Container Configuration",
    "routes":          "Routes",
    "boms":            "BOMs",
    "qualitySpecs":    "Quality Specs",
    "eligibility":     "Eligibility",
}
title = titles.get(sectionKey, sectionKey)
system.perspective.openPopup(
    id="mpp-confirm-unsaved",
    view="BlueRidge/Components/Popups/ConfirmUnsaved",
    modal=True,
    showCloseIcon=False,
    params={
        "title":   "Unsaved Changes",
        "message": "You have unsaved changes to " + title + ". Save before switching?",
    },
)
```

`completeSwitch`:

```python
pending = self.view.custom.pendingSwitch or {}
kind    = pending.get("kind")
target  = pending.get("to")
if kind == "tab":
    sectionKeys = ["containerConfig", "routes", "boms", "qualitySpecs", "eligibility"]
    self.view.custom.activeTabIndex = target
    if target is not None and target < len(sectionKeys):
        self.view.custom.activeTab = sectionKeys[target]
elif kind == "item":
    self.view.custom.selectedItemId = target
self.view.custom.pendingSwitch = None
```

`cancelSwitch`:

```python
self.view.custom.pendingSwitch = None
```

- [ ] **Step 7: Rewrite the parent's `itemRowClicked` message handler**

```python
targetId = payload.get("id") if payload else None
if targetId is None or targetId == self.view.custom.selectedItemId:
    return
dirtyKeys = [k for k, v in (self.view.custom.sectionDirty or {}).items() if v]
if dirtyKeys:
    self.view.custom.pendingSwitch = {"kind": "item", "to": targetId}
    self.rootContainer.openConfirmUnsaved(dirtyKeys[0])
else:
    self.view.custom.selectedItemId = targetId
```

- [ ] **Step 8: Add the two new message handlers on `root.scripts.messageHandlers`**

```json
{
  "messageType": "sectionDirtyChanged",
  "pageScope": true,
  "sessionScope": false,
  "viewScope": false,
  "script": "<see below>"
},
{
  "messageType": "confirmUnsavedResult",
  "pageScope": true,
  "sessionScope": false,
  "viewScope": false,
  "script": "<see below>"
}
```

`sectionDirtyChanged` script:

```python
section = payload.get("section") if payload else None
isDirty = bool(payload.get("isDirty")) if payload else False
if not section:
    return
nextMap = dict(self.view.custom.sectionDirty or {})
nextMap[section] = isDirty
self.view.custom.sectionDirty = nextMap
pending = self.view.custom.pendingSwitch
if pending and not any(nextMap.values()):
    self.rootContainer.completeSwitch()
```

`confirmUnsavedResult` script:

```python
action = payload.get("action") if payload else None
pending = self.view.custom.pendingSwitch
if not pending:
    return
if action == "cancel":
    self.rootContainer.cancelSwitch()
    return
dirtyKeys = [k for k, v in (self.view.custom.sectionDirty or {}).items() if v]
if not dirtyKeys:
    self.rootContainer.completeSwitch()
    return
dirtySection = dirtyKeys[0]
if action == "save":
    system.perspective.sendMessage("sectionSaveRequested", payload={"section": dirtySection}, scope="page")
elif action == "discard":
    system.perspective.sendMessage("sectionDiscardRequested", payload={"section": dirtySection}, scope="page")
# completeSwitch is triggered by the sectionDirtyChanged handler when the dirty flag flips back to false.
```

- [ ] **Step 9: Validate JSON**

```powershell
try { Get-Content 'ignition\projects\MPP_Config\com.inductiveautomation.perspective\views\BlueRidge\Views\Parts\ItemMaster\view.json' -Raw | ConvertFrom-Json | Out-Null; 'OK' } catch { 'BAD: ' + $_.Exception.Message }
```

- [ ] **Step 10: Gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 11: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): parent-side section-dirty gate infrastructure

Per-section ownership pattern (per project_mpp_item_master_pattern).
Demolish the old bundled editDraft / selected / mode props that were
never properly populated. Add selectedItemId, sectionDirty flag map,
pendingSwitch staging, activeTabIndex (mirrors activeTab as int for
tab onChange interception).

Wire ConfirmUnsaved gate:
- Tab clicks intercepted via activeTabIndex onChange; reverts the
  tab and opens ConfirmUnsaved when the current section is dirty.
- Item-row clicks intercepted via the existing itemRowClicked handler;
  opens ConfirmUnsaved when any section is dirty.
- confirmUnsavedResult: save -> sectionSaveRequested, discard ->
  sectionDiscardRequested, cancel -> drop pendingSwitch.
- completeSwitch fires automatically when sectionDirty flips clean
  with a pendingSwitch waiting.

All five tab embeds now receive params.value: selectedItemId (BIGINT,
input-only). The four non-Phase-4 tabs still ignore the param value.

Identity-section input fields are hidden via meta.visible: false until
Phase 3 carves Identity into its own embed. Header buttons (Save /
Deprecate / Add Item) stay as Phase 3 placeholders."
```

---

### Task 6: Designer smoke + Phase 4 close-out

For Jacques, post-merge.

- [ ] **Step 1: Pull latest main**

```bash
git pull --ff-only origin main
```

- [ ] **Step 2: Run gateway scan once more**

```powershell
.\scan.ps1
```

- [ ] **Step 3: Walk the 11-step smoke checklist in spec §7**

`docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` §7. The critical step is #4 (tab-click intercept while dirty). Any FAIL means the gate wiring or message protocol has a defect — halt and triage rather than patching forward.

- [ ] **Step 4: Update PROJECT_STATUS.md**

Move Phase 4 from "open" to "recently closed" with commit range. Note the per-section convention adoption + retrofit pattern.

- [ ] **Step 5: Commit status + push**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): Item Master Phase 4 + per-section pattern landed"
git push origin main
```

---

## Self-Review

- **Spec coverage:** All sections of the spec map to tasks. §2.2 file deltas → Tasks 1-5. §2.3 embed structure → Task 4. §2.4 parent structure → Task 5. §2.5 dirty indicator → Task 5 Step 4. §2.6 gate semantics → Task 5 Steps 5-8. §2.9-§2.13 handler bodies → embedded in Task 4. §3 NQ specs → Tasks 1, 2. §6 risks + §7 smoke → Task 6.
- **Placeholder scan:** No "TBD", no "add appropriate error handling", no "fill in details". Every step has the literal SQL / JSON / Python.
- **Type consistency:** All dict keys PascalCase (DB column names: TraysPerContainer, ClosureMethod, TargetWeight). NQ param keys camelCase. Message payload keys camelCase (`section`, `isDirty`, `action`). `params.value` is a BIGINT in all five tab embeds.
- **R1 explicitly avoided:** params.value is plain BIGINT, never bidi. All cross-embed state flows through page-scoped messages.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-20-item-master-phase4.md`. Companion spec at `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md`. Pattern memory at `project_mpp_item_master_pattern`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task. Phase 4 has 6 tasks; Task 5 is the largest (parent view) and benefits from review between subtasks.
2. **Inline Execution** — execute here in this session using executing-plans, batch with checkpoints.

If a worktree is desired:

```powershell
git worktree add -b item-master-phase4 ..\mpp-worktrees\agent-A-phase4 main
```

**Which approach?**
