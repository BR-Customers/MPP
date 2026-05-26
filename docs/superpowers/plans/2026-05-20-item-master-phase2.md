# Item Master Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Item Master page's items list + Identity header + Container Config tab to live SQL data, building the test bed for the R1 bidi-embed smoke verification.

**Architecture:** Three new Named Queries (Item_List, Item_Get, ContainerConfig_GetByItem) wrap existing stored procs. Two new entity scripts (`BlueRidge.Parts.Item`, `BlueRidge.Parts.ContainerConfig`) route through `Common.Db`. Parent `ItemMaster/view.json` swaps its hardcoded `items`/`selected`/`editDraft` seeds for a runScript binding + a real `itemRowClicked` handler that calls the entity scripts. No SQL changes — existing procs are reused.

**Tech Stack:** Ignition Perspective 8.3 (view.json / NQ resource.json / Jython script-python), SQL Server 2022 (existing procs), PowerShell (scan.ps1).

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md`

---

## File Structure

**New files:**

```
ignition/projects/MPP_Config/ignition/named-query/parts/
├── Item_List/
│   ├── query.sql
│   └── resource.json
├── Item_Get/
│   ├── query.sql
│   └── resource.json
└── ContainerConfig_GetByItem/
    ├── query.sql
    └── resource.json

ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/
├── Item/
│   ├── code.py
│   └── resource.json
└── ContainerConfig/
    ├── code.py
    └── resource.json
```

**Modified files:**

```
ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
    - replace view.custom.items hardcoded array with empty list (rebound via expression)
    - replace view.custom.selected hardcoded fixture with empty default
    - replace view.custom.editDraft hardcoded fixture with empty default
    - add expression binding on view.custom.items (runScript Parts.Item.getAllForList)
    - rewrite messageHandlers[0] (itemRowClicked) to call live entity scripts

ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json
    - bump lastModification.timestamp; clear lastModificationSignature
```

**Not modified:**

- All five tab children (`ContainerConfig`, `Routes`, `Boms`, `QualitySpecs`, `Eligibility`). ContainerConfig already consumes `view.params.value.<field>`.
- `BlueRidge/Components/Parts/ItemMaster/ItemRow/view.json`. Phase 1 wired the row to fire `itemRowClicked` page-scoped; that handler now resolves to a live impl.
- Any SQL. Tests stay at 937/937.

---

## Task 1: Create NQ `parts/Item_List`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_List/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_List/resource.json`

- [ ] **Step 1: Write query.sql**

Content:
```sql
EXEC Parts.Item_List
    @ItemTypeId        = :itemTypeId,
    @SearchText        = :searchText,
    @IncludeDeprecated = :includeDeprecated
```

- [ ] **Step 2: Write resource.json**

Content (clone shape from `quality/DefectCode_List/resource.json`, swap params):
```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-20T00:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "itemTypeId",
        "sqlType": 3
      },
      {
        "type": "Parameter",
        "identifier": "searchText",
        "sqlType": 7
      },
      {
        "type": "Parameter",
        "identifier": "includeDeprecated",
        "sqlType": 6
      }
    ]
  }
}
```

- [ ] **Step 3: Verify files**

Run:
```bash
ls ignition/projects/MPP_Config/ignition/named-query/parts/Item_List/
```
Expected: `query.sql`, `resource.json`.

---

## Task 2: Create NQ `parts/Item_Get`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Get/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/Item_Get/resource.json`

- [ ] **Step 1: Write query.sql**

Content:
```sql
EXEC Parts.Item_Get
    @Id = :id
```

- [ ] **Step 2: Write resource.json**

Content:
```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-20T00:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "id",
        "sqlType": 3
      }
    ]
  }
}
```

---

## Task 3: Create NQ `parts/ContainerConfig_GetByItem`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_GetByItem/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_GetByItem/resource.json`

- [ ] **Step 1: Write query.sql**

Content:
```sql
EXEC Parts.ContainerConfig_GetByItem
    @ItemId = :itemId
```

- [ ] **Step 2: Write resource.json**

Content:
```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-20T00:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "itemId",
        "sqlType": 3
      }
    ]
  }
}
```

---

## Task 4: Create entity script `BlueRidge.Parts.Item`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item/resource.json`

- [ ] **Step 1: Write code.py**

Content:
```python
# =============================================================================
# Project Library:  BlueRidge.Parts.Item
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master Configuration Tool screen
#   (Phase 2). Mutations (add/update/deprecate) land in Phase 3.
#   Routes every DB call through BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   getAll(searchText=None, itemTypeId=None, includeDeprecated=False)
#     -> list[dict]
#   getOne(itemId) -> dict | None
#   mapItemRowsForList(rows, typeFilter='All Types') -> list[dict]
#   typeBadgeFor(itemTypeName) -> str
#   getAllForList(searchText='', typeFilter='All Types') -> list[dict]
#
# Layer:
#   View -> BlueRidge.Parts.Item (this module)
#        -> BlueRidge.Common.Db.execList / execOne
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
# =============================================================================


_TYPE_BADGE = {
    "Finished Good": "FG",
    "Component":     "COMP",
    "Sub-Assembly":  "SA",
    "Raw Material":  "RAW",
    "Pass-Through":  "PT",
}


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def typeBadgeFor(itemTypeName):
    """Returns short-form badge text (FG / COMP / SA / RAW / PT) for the
    given item-type name. Unknown names -> '' (no exception)."""
    return _TYPE_BADGE.get(itemTypeName or "", "")


def getAll(searchText=None, itemTypeId=None, includeDeprecated=False):
    """List items with optional server-side SearchText (PartNumber +
    Description LIKE) and ItemTypeId filter. Includes ItemType.Name and
    Uom.Code joins."""
    BlueRidge.Common.Util.log(
        "searchText=%s itemTypeId=%s includeDeprecated=%s"
        % (searchText, itemTypeId, includeDeprecated))
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Item_List",
            {
                "itemTypeId":        itemTypeId,
                "searchText":        searchText,
                "includeDeprecated": 1 if includeDeprecated else 0,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load items", str(e), "error")
        return []


def getOne(itemId):
    """Single-row Item lookup with ItemType + UOM joins. Returns dict or
    None."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if itemId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/Item_Get",
            {"id": itemId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getOne failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load item", str(e), "error")
        return None


def mapItemRowsForList(rows, typeFilter="All Types"):
    """Flex-repeater instances transform.

    - Filters by ItemTypeName when typeFilter != 'All Types'.
    - Maps DB columns to the ItemRow view-param shape.

    Defensive against Dataset input (Ignition custom-prop layer can coerce
    stored lists back to Dataset when read via expression). Returns
    list[dict] ready for Repeater.props.instances composition."""
    rows = _u(rows)
    if rows is None:
        return []
    if hasattr(rows, "getColumnNames") and hasattr(rows, "getRowCount"):
        headers = list(rows.getColumnNames())
        rows = [dict(zip(headers, row)) for row in rows]
    typeFilter = _u(typeFilter)
    keepAll = (not typeFilter) or typeFilter == "All Types"
    out = []
    for r in rows:
        itemTypeName = r.get("ItemTypeName") or ""
        if (not keepAll) and itemTypeName != typeFilter:
            continue
        out.append({
            "id":           r.get("Id"),
            "partNumber":   r.get("PartNumber") or "",
            "description": r.get("Description") or "",
            "itemTypeId":   r.get("ItemTypeId"),
            "itemTypeName": itemTypeName,
            "typeBadge":    typeBadgeFor(itemTypeName),
            "isDraft":      False,
        })
    return out


def getAllForList(searchText="", typeFilter="All Types"):
    """One-shot getAll + map composed for the expression binding on
    view.custom.items. Server-side filter on SearchText; client-side
    filter on type name."""
    searchText = _u(searchText) or ""
    typeFilter = _u(typeFilter) or "All Types"
    rows = getAll(
        searchText=searchText if searchText.strip() else None,
        itemTypeId=None,
        includeDeprecated=False,
    )
    return mapItemRowsForList(rows, typeFilter)
```

- [ ] **Step 2: Write resource.json**

Content (clone shape from `BlueRidge/Quality/DefectCode/resource.json`):
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "code.py"
  ],
  "attributes": {
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-20T00:00:00Z"
    },
    "lastModificationSignature": ""
  }
}
```

- [ ] **Step 3: Verify resource.json shape**

Run:
```bash
cat ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/resource.json
```
Compare keys with the file just written. Same keys, same shape.

---

## Task 5: Create entity script `BlueRidge.Parts.ContainerConfig`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig/resource.json`

- [ ] **Step 1: Write code.py**

Content:
```python
# =============================================================================
# Project Library:  BlueRidge.Parts.ContainerConfig
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master Container Config tab (Phase 2).
#   Save lands in Phase 4. Routes through BlueRidge.Common.Db.*.
#
# Public surface:
#   getByItem(itemId) -> dict | None
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (getByItem only).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getByItem(itemId):
    """Returns the active ContainerConfig row for the Item, or None.
    Multiple active rows shouldn't exist (filtered unique index), but the
    underlying execOne logs a warning if they do."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if itemId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/ContainerConfig_GetByItem",
            {"itemId": itemId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getByItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load container config", str(e), "error")
        return None
```

- [ ] **Step 2: Write resource.json**

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "code.py"
  ],
  "attributes": {
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-20T00:00:00Z"
    },
    "lastModificationSignature": ""
  }
}
```

---

## Task 6: Wire parent `ItemMaster/view.json` to live data

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json`

- [ ] **Step 1: Replace `view.custom.items` (lines 7-13)**

Find:
```json
    "items": [
      {"id": 1, "partNumber": "5G0",     "description": "Front Cover Assy",    "itemTypeName": "Finished Good", "typeBadge": "FG",   "isDraft": false},
      {"id": 2, "partNumber": "5G0-C",   "description": "Front Cover Casting", "itemTypeName": "Component",     "typeBadge": "COMP", "isDraft": false},
      {"id": 3, "partNumber": "PNA",     "description": "Mounting Pin",        "itemTypeName": "Component",     "typeBadge": "COMP", "isDraft": false},
      {"id": 4, "partNumber": "6MA-HSG", "description": "Cam Holder Housing",  "itemTypeName": "Pass-Through",  "typeBadge": "PT",   "isDraft": true},
      {"id": 5, "partNumber": "RPY",     "description": "Assembly Set",        "itemTypeName": "Finished Good", "typeBadge": "FG",   "isDraft": false}
    ],
```

Replace with:
```json
    "items": [],
```

- [ ] **Step 2: Replace `view.custom.selected` and `view.custom.editDraft` blocks (lines 16-127)**

Find the block from `"selected": {` through `"editDraft": { ... "rows": [{...}, ...] } }` (the entire 5G0 fixture, both blocks).

Replace with:
```json
    "selected": {
      "meta": {},
      "containerConfig": {},
      "routes": {"steps": []},
      "boms": {"lines": []},
      "qualitySpecs": [],
      "eligibility": {"rows": []}
    },
    "editDraft": {
      "meta": {},
      "containerConfig": {},
      "routes": {"steps": []},
      "boms": {"lines": []},
      "qualitySpecs": [],
      "eligibility": {"rows": []}
    }
```

- [ ] **Step 3: Add a `propConfig` binding for `custom.items`**

Add this `propConfig` block at the same level as `"custom"`, `"params"`, `"props"`, `"root"` — i.e., a top-level key of the view object. This wires the items list to a runScript call.

Replace the top-level object opening. Find:
```json
{
  "custom": {
    "search": "",
```

Replace with:
```json
{
  "propConfig": {
    "custom.items": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "runScript(\"BlueRidge.Parts.Item.getAllForList\", 0, {view.custom.search}, {view.custom.typeFilter})"
        }
      }
    }
  },
  "custom": {
    "search": "",
```

- [ ] **Step 4: Rewrite the `itemRowClicked` message handler**

Find (in the `messageHandlers` array at the end of the view):
```json
        {
          "messageType": "itemRowClicked",
          "pageScope": true,
          "viewScope": false,
          "sessionScope": false,
          "script": "\tclickedId = payload.get('id') if payload else None\n\tif clickedId is None:\n\t\treturn\n\tfor it in self.view.custom.items:\n\t\tif it.get('id') == clickedId:\n\t\t\tif it.get('id') == 1:\n\t\t\t\tself.view.custom.editDraft = dict(self.view.custom.selected)\n\t\t\telse:\n\t\t\t\tbundle = {'meta': dict(it), 'containerConfig': {}, 'routes': {'steps': []}, 'boms': {'lines': []}, 'qualitySpecs': [], 'eligibility': {'rows': []}}\n\t\t\t\tself.view.custom.selected  = bundle\n\t\t\t\tself.view.custom.editDraft = dict(bundle)\n\t\t\tself.view.custom.mode = 'update'\n\t\t\tbreak"
        }
```

Replace with:
```json
        {
          "messageType": "itemRowClicked",
          "pageScope": true,
          "viewScope": false,
          "sessionScope": false,
          "script": "\tclickedId = payload.get('id') if payload else None\n\tif clickedId is None:\n\t\treturn\n\titemMeta = BlueRidge.Parts.Item.getOne(clickedId)\n\tif itemMeta is None:\n\t\tBlueRidge.Common.Notify.toast('Item not found', 'Item id ' + str(clickedId) + ' no longer exists.', 'warning')\n\t\treturn\n\tccRow = BlueRidge.Parts.ContainerConfig.getByItem(clickedId) or {}\n\tself.view.custom.selected = {\n\t\t'meta': dict(itemMeta),\n\t\t'containerConfig': dict(ccRow),\n\t\t'routes': {'steps': []},\n\t\t'boms': {'lines': []},\n\t\t'qualitySpecs': [],\n\t\t'eligibility': {'rows': []}\n\t}\n\tself.view.custom.editDraft = {\n\t\t'meta': dict(itemMeta),\n\t\t'containerConfig': dict(ccRow),\n\t\t'routes': {'steps': []},\n\t\t'boms': {'lines': []},\n\t\t'qualitySpecs': [],\n\t\t'eligibility': {'rows': []}\n\t}\n\tself.view.custom.mode = 'update'"
        }
```

- [ ] **Step 5: Bump resource.json metadata**

Open `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json`.

Set:
- `attributes.lastModification.timestamp` to `"2026-05-20T00:00:00Z"`
- `attributes.lastModificationSignature` to `""`

- [ ] **Step 6: Sanity-check JSON**

Run:
```bash
node -e "JSON.parse(require('fs').readFileSync('ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json'))"
```
Expected: no output (parse succeeded).

Also:
```bash
node -e "JSON.parse(require('fs').readFileSync('ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json'))"
```
Expected: no output.

---

## Task 7: Run scan + commit + write smoke checklist appendix

- [ ] **Step 1: Run scan.ps1**

Run from project root:
```powershell
.\scan.ps1
```
Expected: scan triggered against gateway, exit 0. (If gateway is unreachable from this worktree's environment, log the failure but proceed — scan is idempotent and Jacques can re-run.)

- [ ] **Step 2: Verify the new files surface**

```bash
ls ignition/projects/MPP_Config/ignition/named-query/parts/
ls ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/
```
Expected: each directory contains the new sub-folders with files.

- [ ] **Step 3: Append smoke checklist to the design spec**

Open `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md`. Verify that §9 (R1 smoke checklist) is present and complete. No edit needed — Step 3 is a verification gate, not a write.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/Item_List \
        ignition/projects/MPP_Config/ignition/named-query/parts/Item_Get \
        ignition/projects/MPP_Config/ignition/named-query/parts/ContainerConfig_GetByItem \
        ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Item \
        ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/ContainerConfig \
        ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json \
        ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json

git commit -m "feat(item-master): Phase 2 — wire items list + ContainerConfig to live SQL"
```

---

## Task 8: Update PROJECT_STATUS.md + memory + handoff note

**Files:**
- Modify: `PROJECT_STATUS.md`
- Modify: `C:\Users\JacquesPotgieter\.claude\projects\C--Users-JacquesPotgieter-documents-dev-mpp\memory\project_mpp_item_master_pattern.md`

- [ ] **Step 1: Add Phase 2 entry to PROJECT_STATUS.md Recent Change Narrative**

Insert above the existing `### 2026-05-19 — Defect Codes Tasks 1-7` entry, under `## Recent Change Narrative`:

```markdown
### 2026-05-20 — Item Master Phase 2: read paths + R1 smoke test bed

Phase 2 of the 8-phase Item Master Configuration Tool. Three new Named Queries (`parts/Item_List`, `parts/Item_Get`, `parts/ContainerConfig_GetByItem`) wrap existing stored procs. Two new entity scripts (`BlueRidge.Parts.Item`, `BlueRidge.Parts.ContainerConfig`) route through `Common.Db`. The parent `ItemMaster/view.json` now binds `view.custom.items` to a `runScript(BlueRidge.Parts.Item.getAllForList, ...)` expression and its `itemRowClicked` handler calls the live entity scripts to populate `view.custom.editDraft.meta` + `view.custom.editDraft.containerConfig` from the DB. The other four tab slices (routes/boms/qualitySpecs/eligibility) are left empty until their own phases land.

**No SQL changes.** Tests stay at 937/937 (existing `Parts.Item_List`, `Parts.Item_Get`, `Parts.ContainerConfig_GetByItem` reused as-is).

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md`
**Plan:** `docs/superpowers/plans/2026-05-20-item-master-phase2.md`

**Files touched (8 created + 2 modified):**
- 3 new NQ folders under `ignition/projects/MPP_Config/ignition/named-query/parts/`
- 2 new entity script modules under `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/`
- 1 view edit + resource.json metadata bump on `BlueRidge/Views/Parts/ItemMaster/`

**R1 smoke verification — PENDING** (Designer smoke checklist in spec §9). R1 holding is the precondition for Phase 3-8 building on the bidi-embed pattern. If smoke fails: page-scoped message fallback documented in spec §2 governs the rebuild.

**Next pickup:** Jacques walks the R1 smoke in Designer. On pass → Phase 3 (Item Save / Deprecate / Add Item Create) brainstorming. On fail → fallback design cycle.
```

- [ ] **Step 2: Update memory entry**

Edit `~/.claude/projects/C--Users-JacquesPotgieter-documents-dev-mpp/memory/project_mpp_item_master_pattern.md`. Locate the "8-phase roadmap" line and the R1 risk paragraph; mark Phase 2 as DONE and R1 as "smoke pending Designer-side verification" (or whatever Jacques's later verdict makes it). Use this replacement for the relevant lines:

Replace:
```
- **Parent ↔ child state coupling:** parent's Embedded View `props.params.value` bidi-bound to `view.custom.editDraft.<slice>`; child declares `params.value` with `paramDirection: "input"`; form fields inside child bidi to `view.params.value.<field>`. **R1 risk:** this round-trip pattern was not exercised before this build — Designer smoke MUST verify that editing a field inside an embedded tab flips the parent's `● Unsaved changes` indicator. Fallback (per-tab editDraft on child + page-scoped change messages back to parent) documented in spec § R1.
```

With:
```
- **Parent ↔ child state coupling:** parent's Embedded View `props.params.value` bidi-bound to `view.custom.editDraft.<slice>`; child declares `params.value` with `paramDirection: "input"`; form fields inside child bidi to `view.params.value.<field>`. **R1 status:** test bed built in Phase 2 (2026-05-20) — Container Config tab populated from real DB, smoke walk pending Designer verification by Jacques. Update this line once R1 verdict is in. Fallback (per-tab editDraft on child + page-scoped change messages back to parent) documented in spec § R1.
```

Also replace `1 = shell + dummy data (DONE 2026-05-19, smoke pending)` with `1 = shell + dummy data (DONE 2026-05-19); 2 = read paths + R1 smoke bed (DONE 2026-05-20, smoke pending)`, and shift the remaining numbered phases by one.

- [ ] **Step 3: Commit status + memory update**

```bash
git add PROJECT_STATUS.md docs/superpowers/plans/2026-05-20-item-master-phase2.md
git commit -m "docs(status): Item Master Phase 2 landed; R1 smoke pending"
```

(Memory file is outside the worktree — write it directly via the user's home-dir memory path.)

- [ ] **Step 4: Write handoff note as final user-facing message**

End-of-session message must include:
- R1 smoke verdict: NOT YET (smoke pending Designer verification).
- What landed in Phase 2: 3 NQs + 2 entity scripts + parent view rewire. No SQL changes.
- The R1 smoke checklist location (spec §9).
- Phase 3 prep: Item save / deprecate / add — including the `PartsPerBasket` cleanup noted in spec §3.3.
- Whether the worktree is ready to merge or should wait for the smoke verdict.

---

## Self-Review Notes

1. **Spec coverage:** Spec §2 (R1 smoke) → Task 6 + Task 7 (smoke bed exists; checklist in spec §9 is the verification artifact). §3.2 file deltas → Tasks 1-6 enumerate each file. §3.4 items binding → Task 6 Step 3. §3.5 itemRowClicked handler → Task 6 Step 4. §3.6 initial state → Task 6 Step 2. §4 NQ specifics → Tasks 1-3. §5 entity script specifics → Tasks 4-5. §9 R1 smoke checklist → already in spec; verified by Task 7 Step 3.

2. **Placeholder scan:** No TBDs/TODOs in tasks. All file paths absolute. Code blocks present for every code step.

3. **Type consistency:** `BlueRidge.Parts.Item.getAllForList(searchText, typeFilter)` referenced in Task 6 Step 3 matches the signature defined in Task 4. `BlueRidge.Parts.Item.getOne(itemId)` matches Task 4. `BlueRidge.Parts.ContainerConfig.getByItem(itemId)` matches Task 5. Item meta dict keys (`Id`, `PartNumber`, `Description`, `ItemTypeName`, `UomCode`, etc.) match the SELECT shape from `Parts.Item_List` / `Parts.Item_Get` per spec §3.3 and SQL inspection.

4. **Out-of-scope deferrals locked:** Item create/update/deprecate is Phase 3 (not in this plan). ContainerConfig save is Phase 4 (not in this plan). Other tabs (Routes/BOMs/QualitySpecs/Eligibility) stay on dummy data in Phase 2 — explicit empty defaults written, no live reads attempted.
