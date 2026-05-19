# Downtime Codes Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pipe live data into the existing `BlueRidge/Views/Oee/DowntimeCodes` view and add a single popup editor modal that supports both Create and Update flows for downtime reason codes.

**Architecture:** Three-layer Ignition stack — Perspective view → entity script (`BlueRidge.Oee.*`) → `Common.Db` helper → existing SQL stored procs (already built and tested). New popup `BlueRidge/Components/Popups/DowntimeCodeEditor` follows the established mode-discriminator pattern with `view.custom.editDraft` / `selected` state and the reusable `ConfirmUnsaved` close-confirmation popup.

**Tech Stack:** Ignition 8.3 Perspective (file-based project), Jython 2.7 entity scripts, Named Queries v2 schema, SQL Server 2022 (existing procs in `Oee.*` schema).

**Spec:** `docs/superpowers/specs/2026-05-19-downtime-codes-wiring-design.md`

---

## Prerequisites for the implementer

Before starting, confirm:

1. The dev Ignition gateway is reachable at `http://localhost:8088`.
2. Token file exists at `C:\Users\JacquesPotgieter\Documents\git-sync-api-key.txt` (used by `scan.ps1`).
3. The user has Designer open against the `MPP_Config` project for end-to-end smoke testing.
4. `BlueRidge.Common.Db`, `BlueRidge.Common.Ui`, `BlueRidge.Common.Util`, `BlueRidge.Common.Notify` modules exist (they do — built in the 2026-05-14 convention rectification).

**Key conventions to follow:**

- **NQ resource.json:** `"version": 2`, camelCase param `identifier`, Designer sqlType enum (BIGINT=3, NVARCHAR=7, BIT=6).
- **NQ query.sql:** thin `EXEC schema.proc @ProcParam = :nqParam` wrappers. NQ params are camelCase; proc params follow the proc's declaration (PascalCase in this project).
- **Entity scripts:** Three-layer rule — only `Common.Db.*` calls `system.db.*`. Unwrap inputs at the boundary via `BlueRidge.Common.Util.extractQualifiedValues` (alias `_u`).
- **Status check:** `if result.get("Status"):` (truthy check — robust to BIT mapping as bool/int/long).
- **`@AppUserId`** comes from `BlueRidge.Common.Util._currentAppUserId()` — never from caller.
- **Gateway scan:** run `.\scan.ps1` from project root after writing any new resource file.
- **Existing-view file-edit boundary:** Claude may file-edit `view.json` for *existing* views ONLY if the user has closed that view's tab in Designer first. New views (DowntimeCodeEditor popup) have no Designer cache and can be written freely.
- **GSON escapes in view.json scripts:** Designer escapes `=`/`'`/`<`/`>`/`&` as 6-char unicode literals. When writing new view.json content, literal `=` is fine — Designer will normalize on its next save. Diff churn is acceptable.
- **No `customMethods`** at `root.scripts.customMethods` — addressing is broken there (see PROJECT_STATUS.md audit-pages bug). Use inline 1-line dispatch into entity-script functions for all button handlers.
- **Commits:** no `Co-Authored-By: Claude` trailer.

---

## File structure

**Create (new):**

```
ignition/projects/MPP_Config/ignition/named-query/oee/
├─ DowntimeReasonCode_List/         { query.sql, resource.json }
├─ DowntimeReasonCode_Get/          { query.sql, resource.json }
├─ DowntimeReasonCode_Create/       { query.sql, resource.json }
├─ DowntimeReasonCode_Update/       { query.sql, resource.json }
├─ DowntimeReasonCode_Deprecate/    { query.sql, resource.json }
└─ DowntimeReasonType_List/         { query.sql, resource.json }

ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/
├─ DowntimeReasonCode/              { code.py, resource.json }
└─ DowntimeReasonType/              { code.py, resource.json }

ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/
└─ Components/Popups/DowntimeCodeEditor/   { view.json, resource.json }
```

**Modify (existing — closed-tab protocol applies):**

```
ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py
ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Oee/DowntimeCodes/view.json
ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DowntimeCodeRow/view.json
```

---

## Task 1: Verify proc parameter names + canonical NQ shape

**Why:** Before writing 6 NQs, confirm the exact parameter names declared on the underlying procs (project convention is PascalCase but we need to match what the proc actually exposes) and confirm an existing project NQ's canonical `resource.json` shape to mirror.

**Files (read-only):**
- Read: `sql/migrations/repeatable/R__Oee_DowntimeReasonCode_List.sql`
- Read: `sql/migrations/repeatable/R__Oee_DowntimeReasonCode_Get.sql`
- Read: `sql/migrations/repeatable/R__Oee_DowntimeReasonCode_Create.sql`
- Read: `sql/migrations/repeatable/R__Oee_DowntimeReasonCode_Update.sql`
- Read: `sql/migrations/repeatable/R__Oee_DowntimeReasonCode_Deprecate.sql`
- Read: `sql/migrations/repeatable/R__Oee_DowntimeReasonType_List.sql`
- Read: `ignition/projects/MPP_Config/ignition/named-query/location/Location_SaveAll/resource.json` (or any existing project NQ resource.json) — reference for the canonical v2 schema field order

- [ ] **Step 1:** Read each of the 6 proc files and record:
    - Exact `@ParamName` declarations and their datatypes
    - Whether the List/Get procs do their own JOINs to surface `AreaName`, `TypeName`, `IsDeprecated` (likely yes) — confirm result-set column names

- [ ] **Step 2:** Read an existing project NQ `resource.json` to capture the canonical attribute field order Designer uses. Note the exact JSON shape.

- [ ] **Step 3:** Write down a short reference table (in a scratch note or in the next task's docstring) mapping NQ params → proc params for each of the 6 NQs. Used as the source of truth for Task 2.

- [ ] **Step 4:** No commit — this is research.

---

## Task 2: Create 6 named queries under `named-query/oee/`

**Files (create):**
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_List/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_List/resource.json`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Get/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Get/resource.json`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Create/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Create/resource.json`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Update/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Update/resource.json`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Deprecate/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonCode_Deprecate/resource.json`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonType_List/query.sql`
- Create: `ignition/projects/MPP_Config/ignition/named-query/oee/DowntimeReasonType_List/resource.json`

- [ ] **Step 1: Write `DowntimeReasonCode_List` query.sql + resource.json**

`query.sql` (adjust `@ProcParam` names to match what Task 1 confirmed):

```sql
EXEC Oee.DowntimeReasonCode_List
    @AreaLocationId       = :areaLocationId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @SearchText           = :searchText,
    @IncludeDeprecated    = :includeDeprecated
```

`resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "files": ["query.sql"],
  "attributes": {
    "type": "Query",
    "enabled": true,
    "database": "",
    "useMaxReturnSize": false,
    "maxReturnSize": 100,
    "autoBatchEnabled": false,
    "cacheEnabled": false,
    "cacheAmount": 1,
    "cacheUnit": "SEC",
    "fallbackEnabled": false,
    "fallbackValue": "",
    "permissions": [{ "zone": "", "role": "" }],
    "parameters": [
      { "type": "Parameter", "identifier": "areaLocationId",       "sqlType": 3 },
      { "type": "Parameter", "identifier": "downtimeReasonTypeId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "searchText",           "sqlType": 7 },
      { "type": "Parameter", "identifier": "includeDeprecated",    "sqlType": 6 }
    ]
  }
}
```

- [ ] **Step 2: Write `DowntimeReasonCode_Get`**

`query.sql`:

```sql
EXEC Oee.DowntimeReasonCode_Get @Id = :id
```

`resource.json` — same shape as Step 1 but `parameters` is:

```json
"parameters": [
  { "type": "Parameter", "identifier": "id", "sqlType": 3 }
]
```

- [ ] **Step 3: Write `DowntimeReasonCode_Create`**

`query.sql`:

```sql
EXEC Oee.DowntimeReasonCode_Create
    @Code                 = :code,
    @Description          = :description,
    @AreaLocationId       = :areaLocationId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @IsExcused            = :isExcused,
    @AppUserId            = :appUserId
```

`resource.json` — `type: "Query"` (mutation procs end with a SELECT row; we want the Dataset back through `runNamedQuery`), `parameters`:

```json
"parameters": [
  { "type": "Parameter", "identifier": "code",                 "sqlType": 7 },
  { "type": "Parameter", "identifier": "description",          "sqlType": 7 },
  { "type": "Parameter", "identifier": "areaLocationId",       "sqlType": 3 },
  { "type": "Parameter", "identifier": "downtimeReasonTypeId", "sqlType": 3 },
  { "type": "Parameter", "identifier": "isExcused",            "sqlType": 6 },
  { "type": "Parameter", "identifier": "appUserId",            "sqlType": 3 }
]
```

- [ ] **Step 4: Write `DowntimeReasonCode_Update`**

`query.sql`:

```sql
EXEC Oee.DowntimeReasonCode_Update
    @Id                   = :id,
    @Description          = :description,
    @AreaLocationId       = :areaLocationId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @IsExcused            = :isExcused,
    @AppUserId            = :appUserId
```

`resource.json` — same shape, `parameters`:

```json
"parameters": [
  { "type": "Parameter", "identifier": "id",                   "sqlType": 3 },
  { "type": "Parameter", "identifier": "description",          "sqlType": 7 },
  { "type": "Parameter", "identifier": "areaLocationId",       "sqlType": 3 },
  { "type": "Parameter", "identifier": "downtimeReasonTypeId", "sqlType": 3 },
  { "type": "Parameter", "identifier": "isExcused",            "sqlType": 6 },
  { "type": "Parameter", "identifier": "appUserId",            "sqlType": 3 }
]
```

- [ ] **Step 5: Write `DowntimeReasonCode_Deprecate`**

`query.sql`:

```sql
EXEC Oee.DowntimeReasonCode_Deprecate
    @Id        = :id,
    @AppUserId = :appUserId
```

`resource.json` — same shape, `parameters`:

```json
"parameters": [
  { "type": "Parameter", "identifier": "id",        "sqlType": 3 },
  { "type": "Parameter", "identifier": "appUserId", "sqlType": 3 }
]
```

- [ ] **Step 6: Write `DowntimeReasonType_List`**

`query.sql`:

```sql
EXEC Oee.DowntimeReasonType_List
```

`resource.json` — same shape but `parameters: []`. Consider enabling caching since the 6 types never change at runtime:

```json
"cacheEnabled": true,
"cacheAmount": 30,
"cacheUnit": "MIN",
...
"parameters": []
```

- [ ] **Step 7: Trigger gateway scan**

```powershell
.\scan.ps1
```

Expected output: `200` response with `scanActive: true` then `scanActive: false`.

- [ ] **Step 8: Verify in Designer**

User action: Project → Update Project. Then double-click each new NQ under `Named Queries → oee/` and confirm: no Designer NPE, params shown with correct types in the Authoring panel.

- [ ] **Step 9: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/oee/
git commit -m "feat(oee-nq): downtime reason code + type named queries"
```

---

## Task 3: Create `DowntimeReasonType` entity script

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonType/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonType/resource.json`

- [ ] **Step 1: Write `code.py`**

```python
"""BlueRidge.Oee.DowntimeReasonType — read-only access to the 6 seeded types."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getAll():
    """List all DowntimeReasonType rows. Returns list[dict] keyed by SELECT aliases.
       Result is small (6 rows) and stable; NQ has 30-min cache enabled."""
    BlueRidge.Common.Util.log("running")
    try:
        return BlueRidge.Common.Db.execList("oee/DowntimeReasonType_List")
    except Exception as e:
        BlueRidge.Common.Util.log("ERROR %s" % str(e))
        return []


def getForDropdown(includeUnassigned=False, includeAll=False):
    """Returns [{label, value}] for ia.input.dropdown.

       includeUnassigned: prepends {label: '(Unassigned)', value: None}
         for filter sidebars that need to surface DowntimeReasonCode rows with NULL TypeId.
       includeAll: prepends {label: 'All Types', value: None}
         for the filter sidebar's 'no type filter' option.

       Filter sidebar typically calls with (True, True); editor popup calls with defaults."""
    rows = getAll()
    out = [{"label": r.get("Name") or "", "value": r.get("Id")} for r in rows]
    if includeUnassigned:
        out.insert(0, {"label": "(Unassigned)", "value": None})
    if includeAll:
        out.insert(0, {"label": "All Types", "value": None})
    return out
```

- [ ] **Step 2: Write `resource.json`**

```json
{
  "scope": "A",
  "version": 1,
  "files": ["code.py"],
  "attributes": {
    "hintScope": 2
  }
}
```

- [ ] **Step 3: Trigger gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Smoke-test from Designer Script Console**

User runs in Script Console:

```python
print BlueRidge.Oee.DowntimeReasonType.getAll()
print BlueRidge.Oee.DowntimeReasonType.getForDropdown(True, True)
```

Expected: 6 rows from `getAll()`, 8 entries from `getForDropdown(True, True)` with "All Types" then "(Unassigned)" then the 6 real types.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonType/
git commit -m "feat(oee-script): DowntimeReasonType entity script (read-only)"
```

---

## Task 4: Create `DowntimeReasonCode` entity script

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonCode/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonCode/resource.json`

- [ ] **Step 1: Write `code.py`**

```python
"""BlueRidge.Oee.DowntimeReasonCode — full CRUD for downtime reason codes.

   All public functions unwrap QualifiedValue wrappers at entry via _u() so
   bidirectional-bound view properties can be passed straight through."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filters=None):
    """List DowntimeReasonCode rows filtered by the supplied dict.

       filters keys (all optional):
         areaLocationId        BIGINT or None
         downtimeReasonTypeId  BIGINT or None
         searchText            string or None (LIKE on Code + Description in proc)
         includeDeprecated     bool (default False)"""
    BlueRidge.Common.Util.log("filters=%s" % filters)
    f = _u(filters) or {}
    params = {
        "areaLocationId":       f.get("areaLocationId"),
        "downtimeReasonTypeId": f.get("downtimeReasonTypeId"),
        "searchText":           f.get("searchText"),
        "includeDeprecated":    bool(f.get("includeDeprecated", False)),
    }
    try:
        return BlueRidge.Common.Db.execList("oee/DowntimeReasonCode_List", params)
    except Exception as e:
        BlueRidge.Common.Util.log("ERROR %s" % str(e))
        BlueRidge.Common.Notify.toast("Failed to load downtime codes", str(e), "error")
        return []


def getOne(id):
    """Single-row lookup by Id. Returns dict or None."""
    BlueRidge.Common.Util.log("id=%s" % id)
    if id is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne("oee/DowntimeReasonCode_Get", {"id": id})
    except Exception as e:
        BlueRidge.Common.Util.log("ERROR %s" % str(e))
        return None


def add(meta):
    """Create. meta = {code, description, areaLocationId, downtimeReasonTypeId, isExcused}.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "code":                 m.get("code"),
        "description":          m.get("description"),
        "areaLocationId":       m.get("areaLocationId"),
        "downtimeReasonTypeId": m.get("downtimeReasonTypeId"),
        "isExcused":            bool(m.get("isExcused", False)),
        "appUserId":            BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Create", params)


def update(meta):
    """Update. meta = {id, description, areaLocationId, downtimeReasonTypeId, isExcused}.
       Returns {Status, Message}. (Code is immutable post-create; proc rejects changes.)"""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "id":                   m.get("id"),
        "description":          m.get("description"),
        "areaLocationId":       m.get("areaLocationId"),
        "downtimeReasonTypeId": m.get("downtimeReasonTypeId"),
        "isExcused":            bool(m.get("isExcused", False)),
        "appUserId":            BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Update", params)


def deprecate(id):
    """Soft-delete by Id. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("id=%s" % id)
    params = {
        "id":        _u(id),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Deprecate", params)


def emptyMeta():
    """Blank meta dict for editor create-mode initialization."""
    return {
        "id":                   None,
        "code":                 "",
        "description":          "",
        "areaLocationId":       None,
        "downtimeReasonTypeId": None,
        "isExcused":            False,
    }
```

Also import `BlueRidge.Common.Notify` at the top (used in `search()`):

```python
import BlueRidge.Common.Db
import BlueRidge.Common.Notify
import BlueRidge.Common.Util
```

- [ ] **Step 2: Write `resource.json`**

```json
{
  "scope": "A",
  "version": 1,
  "files": ["code.py"],
  "attributes": {
    "hintScope": 2
  }
}
```

- [ ] **Step 3: Trigger gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Smoke-test from Designer Script Console**

User runs:

```python
# Read paths
rows = BlueRidge.Oee.DowntimeReasonCode.search({})
print "Total rows:", len(rows)
print rows[0] if rows else "(no rows yet — load seed first if you want to see data)"

# Filter by area (assuming Area location id 3 exists — adjust per your DB)
print len(BlueRidge.Oee.DowntimeReasonCode.search({"areaLocationId": 3}))

# Single-row
print BlueRidge.Oee.DowntimeReasonCode.getOne(1)
```

Expected: `search({})` returns a list (possibly empty if seed not yet loaded); no exceptions; log entries appear in `tail` of `wrapper.log`.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/DowntimeReasonCode/
git commit -m "feat(oee-script): DowntimeReasonCode entity script (CRUD)"
```

---

## Task 5: Add `getAllAreas()` helper to Location entity script

**Why:** The Area dropdown in both the DowntimeCodes view's filter sidebar and the DowntimeCodeEditor popup needs `[{label, value}]` for the 3 Area-tier Locations. Adding a small helper to the existing Location module is cleaner than a new NQ — MPP has only 3 Areas, so client-side filtering is fine.

**Files:**
- Modify: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py`

- [ ] **Step 1: Read the existing file**

Note the imports + existing function shapes (`getAll`, `getOne`, `add`, etc.) — match their conventions.

- [ ] **Step 2: Add `getAllAreas()` near the other read functions**

Append (or insert after the existing `getAll` block):

```python
def getAllAreas(includeAll=False):
    """Returns Area-tier Locations (hierarchyLevel == 3) as [{label, value}] for dropdowns.

       MPP has 3 Areas (Die Cast / Machine Shop / Trim Shop). Client-side filter is fine
       at this scale — no new NQ needed.

       includeAll: prepends {label: 'All Areas', value: None}
         for filter sidebars; editor popup calls with default (False)."""
    BlueRidge.Common.Util.log("running")
    rows = getAll() or []
    areas = [r for r in rows if r.get("hierarchyLevel") == 3]
    out = [{"label": r.get("name") or "", "value": r.get("id")} for r in areas]
    if includeAll:
        out.insert(0, {"label": "All Areas", "value": None})
    return out
```

**Note:** if the existing `getAll()` returns dicts with PascalCase keys (`HierarchyLevel`, `Name`, `Id`) — adjust the dict-key lookups accordingly. The Phase 1 NQ rectification standardized on camelCase (`hierarchyLevel`, `name`, `id`), so camelCase is the expected shape, but verify before committing.

- [ ] **Step 3: Trigger gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Smoke-test from Designer Script Console**

```python
print BlueRidge.Location.Location.getAllAreas()
```

Expected: 3 entries — e.g., `[{'label': 'Die Cast', 'value': 5}, {'label': 'Machine Shop', 'value': 6}, {'label': 'Trim Shop', 'value': 7}]` (actual ids vary by DB seed).

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py
git commit -m "feat(location-script): add getAllAreas() helper for area dropdowns"
```

---

## Task 6: End-to-end entity-layer smoke test (verification gate)

**Why:** Before touching any view, confirm the whole entity layer round-trips correctly against the DB. If anything is broken at this layer, fixing it now is dramatically cheaper than diagnosing via a Perspective UI symptom later.

**Files:** None modified.

- [ ] **Step 1: Run a full CRUD round-trip from Script Console**

User runs each block in sequence and confirms outputs:

```python
# 1. Confirm types load
print BlueRidge.Oee.DowntimeReasonType.getAll()
# Expected: 6 rows with Equipment, Mold, Quality, Setup, Misc, Unscheduled

# 2. Confirm initial list (may be empty)
print "Before:", len(BlueRidge.Oee.DowntimeReasonCode.search({}))

# 3. Create a test code
result = BlueRidge.Oee.DowntimeReasonCode.add({
    "code":                 "DC-TEST-001",
    "description":          "Smoke-test row, delete me",
    "areaLocationId":       BlueRidge.Location.Location.getAllAreas()[0]["value"],
    "downtimeReasonTypeId": BlueRidge.Oee.DowntimeReasonType.getAll()[0]["Id"],
    "isExcused":            False,
})
print "Create:", result
# Expected: {'Status': 1 (or True), 'Message': '...', 'NewId': <int>}

newId = result.get("NewId")

# 4. Get it back
print "Get:", BlueRidge.Oee.DowntimeReasonCode.getOne(newId)

# 5. Update it
result = BlueRidge.Oee.DowntimeReasonCode.update({
    "id":                   newId,
    "description":          "Smoke-test row UPDATED",
    "areaLocationId":       BlueRidge.Location.Location.getAllAreas()[0]["value"],
    "downtimeReasonTypeId": BlueRidge.Oee.DowntimeReasonType.getAll()[0]["Id"],
    "isExcused":            True,
})
print "Update:", result
# Expected: {'Status': 1, 'Message': '...'}

# 6. Confirm update landed
print "After update:", BlueRidge.Oee.DowntimeReasonCode.getOne(newId)

# 7. Deprecate it
print "Deprecate:", BlueRidge.Oee.DowntimeReasonCode.deprecate(newId)

# 8. Confirm it's gone from default list
codes = BlueRidge.Oee.DowntimeReasonCode.search({})
print "After deprecate (default):", len(codes), "rows"

# 9. Confirm it appears with includeDeprecated=True
codes = BlueRidge.Oee.DowntimeReasonCode.search({"includeDeprecated": True})
print "After deprecate (include):", len([c for c in codes if c.get("Code") == "DC-TEST-001"])
# Expected: 1
```

- [ ] **Step 2: Verify failure paths**

```python
# Duplicate code rejection
result = BlueRidge.Oee.DowntimeReasonCode.add({
    "code":                 "DC-TEST-001",   # already exists
    "description":          "Should fail",
    "areaLocationId":       BlueRidge.Location.Location.getAllAreas()[0]["value"],
    "downtimeReasonTypeId": None,
    "isExcused":            False,
})
print result
# Expected: {'Status': 0, 'Message': '...duplicate...', 'NewId': None}
```

- [ ] **Step 3:** If any failures, fix in the relevant entity script or NQ — do NOT proceed to UI tasks until all green.

- [ ] **Step 4:** No commit — this is a verification gate.

---

## Task 7: Create `DowntimeCodeEditor` popup view

**Why this comes before view modifications:** The popup is a brand-new view (no Designer cache to conflict with), so it's safe to file-edit. The DowntimeCodes parent view needs to reference `BlueRidge/Components/Popups/DowntimeCodeEditor` in its "+Add Code" button, so building the popup first means the parent-view wiring task lands fully working.

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DowntimeCodeEditor/view.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DowntimeCodeEditor/resource.json`

- [ ] **Step 1: Read the reference implementation**

Read `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/LocationTypeEditor/view.json` end-to-end. Mirror its structure for: HeaderBar with title + dirty indicator + CloseIcon; FormBody as flex column; FooterBar with left-Deprecate / right-Cancel-Save; ConfirmUnsaved wiring on close.

Also read `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfirmUnsaved/view.json` to confirm the `replyMessage` and `popupId` params it takes.

- [ ] **Step 2: Write `view.json`**

Structure (paste this exact JSON, adjusting style class names to project conventions you see in LocationTypeEditor):

```json
{
  "custom": {
    "selected":      { "meta": null },
    "editDraft":     { "meta": null },
    "areaOptions":   [],
    "typeOptions":   []
  },
  "params": {
    "mode":   "create",
    "editId": null
  },
  "propConfig": {
    "params.mode":   { "paramDirection": "input", "persistent": true },
    "params.editId": { "paramDirection": "input", "persistent": true },
    "custom.areaOptions": {
      "binding": {
        "type": "expr",
        "config": { "expression": "runScript(\"BlueRidge.Location.Location.getAllAreas\", 0)" }
      }
    },
    "custom.typeOptions": {
      "binding": {
        "type": "expr",
        "config": { "expression": "runScript(\"BlueRidge.Oee.DowntimeReasonType.getForDropdown\", 0, false)" }
      }
    },
    "params.editId": {
      "paramDirection": "input",
      "persistent": true,
      "onChange": {
        "enabled": true,
        "script": "\tnewId = currentValue.value\n\tif newId is None:\n\t\tself.view.custom.selected = {\"meta\": BlueRidge.Oee.DowntimeReasonCode.emptyMeta()}\n\telse:\n\t\trow = BlueRidge.Oee.DowntimeReasonCode.getOne(newId)\n\t\tself.view.custom.selected = {\"meta\": row} if row else {\"meta\": BlueRidge.Oee.DowntimeReasonCode.emptyMeta()}\n\tself.view.custom.editDraft = {\"meta\": dict(self.view.custom.selected[\"meta\"])}"
      }
    }
  },
  "props": {
    "defaultSize": { "width": 560, "height": 520 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "column",
      "style": { "classes": "popup-shell" }
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": { "name": "HeaderBar" },
        "position": { "basis": "44px", "shrink": 0 },
        "props": { "direction": "row", "alignItems": "center", "justify": "space-between", "style": { "classes": "popup-header" } },
        "children": [
          {
            "type": "ia.display.label",
            "meta": { "name": "TitleLabel" },
            "props": { "style": { "classes": "popup-title" } },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": { "expression": "if({view.params.mode} = \"create\", \"Add Downtime Code\", \"Edit Downtime Code\")" }
                }
              }
            }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "DirtyIndicator" },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": { "expression": "if({view.custom.editDraft} != {view.custom.selected}, \"● Unsaved changes\", \"\")" }
                }
              }
            }
          },
          {
            "type": "ia.display.icon",
            "meta": { "name": "CloseIcon" },
            "props": { "path": "material/close", "style": { "classes": "popup-close-icon" } },
            "events": {
              "dom": {
                "onClick": {
                  "type": "script",
                  "scope": "C",
                  "config": {
                    "script": "\tif self.view.custom.editDraft == self.view.custom.selected:\n\t\tsystem.perspective.closePopup(id=\"mpp-downtime-code-editor\")\n\telse:\n\t\tsystem.perspective.openPopup(id=\"mpp-confirm-unsaved\", view=\"BlueRidge/Components/Popups/ConfirmUnsaved\", modal=True, showCloseIcon=False, params={\"title\": \"Unsaved Changes\", \"message\": \"You have unsaved changes to this downtime code. Save before closing?\"})"
                  }
                }
              }
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "FormBody" },
        "position": { "grow": 1 },
        "props": { "direction": "column", "style": { "classes": "popup-form-body" } },
        "children": [
          {
            "type": "ia.input.text-field",
            "meta": { "name": "CodeInput" },
            "props": { "placeholder": "e.g. DC-0050" },
            "propConfig": {
              "props.text": {
                "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.editDraft.meta.code" } }
              },
              "props.readOnly": {
                "binding": { "type": "expr", "config": { "expression": "{view.params.mode} = \"update\"" } }
              }
            }
          },
          {
            "type": "ia.input.text-field",
            "meta": { "name": "DescriptionInput" },
            "propConfig": {
              "props.text": {
                "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.editDraft.meta.description" } }
              }
            }
          },
          {
            "type": "ia.input.dropdown",
            "meta": { "name": "AreaDropdown" },
            "propConfig": {
              "props.options": { "binding": { "type": "property", "config": { "path": "view.custom.areaOptions" } } },
              "props.value": { "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.editDraft.meta.areaLocationId" } } }
            }
          },
          {
            "type": "ia.input.dropdown",
            "meta": { "name": "ReasonTypeDropdown" },
            "propConfig": {
              "props.options": { "binding": { "type": "property", "config": { "path": "view.custom.typeOptions" } } },
              "props.value": { "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.editDraft.meta.downtimeReasonTypeId" } } }
            }
          },
          {
            "type": "ia.input.checkbox",
            "meta": { "name": "ExcusedCheckbox" },
            "props": { "text": "Excused (excluded from OEE availability)" },
            "propConfig": {
              "props.selected": { "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.editDraft.meta.isExcused" } } }
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "FooterBar" },
        "position": { "basis": "56px", "shrink": 0 },
        "props": { "direction": "row", "alignItems": "center", "justify": "space-between", "style": { "classes": "popup-footer" } },
        "children": [
          {
            "type": "ia.input.button",
            "meta": { "name": "DeprecateButton" },
            "props": { "text": "Deprecate", "style": { "classes": "btn btn-danger btn-sm" } },
            "propConfig": {
              "position.display": { "binding": { "type": "expr", "config": { "expression": "{view.params.mode} = \"update\"" } } }
            },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "G",
                  "config": {
                    "script": "\tresult = BlueRidge.Oee.DowntimeReasonCode.deprecate(self.view.params.editId)\n\tBlueRidge.Common.Ui.notifyResult(result, \"Downtime code deprecated\")\n\tif result and result.get(\"Status\"):\n\t\tsystem.perspective.sendMessage(\"downtimeCodesRefresh\", scope=\"page\")\n\t\tsystem.perspective.closePopup(id=\"mpp-downtime-code-editor\")"
                  }
                }
              }
            }
          },
          {
            "type": "ia.container.flex",
            "meta": { "name": "RightCluster" },
            "props": { "direction": "row", "alignItems": "center", "gap": 8 },
            "children": [
              {
                "type": "ia.input.button",
                "meta": { "name": "CancelButton" },
                "props": { "text": "Cancel", "style": { "classes": "btn btn-sm" } },
                "events": {
                  "component": {
                    "onActionPerformed": {
                      "type": "script",
                      "scope": "C",
                      "config": {
                        "script": "\tif self.view.custom.editDraft == self.view.custom.selected:\n\t\tsystem.perspective.closePopup(id=\"mpp-downtime-code-editor\")\n\telse:\n\t\tsystem.perspective.openPopup(id=\"mpp-confirm-unsaved\", view=\"BlueRidge/Components/Popups/ConfirmUnsaved\", modal=True, showCloseIcon=False, params={\"title\": \"Unsaved Changes\", \"message\": \"You have unsaved changes to this downtime code. Save before closing?\"})"
                      }
                    }
                  }
                }
              },
              {
                "type": "ia.input.button",
                "meta": { "name": "SaveButton" },
                "props": { "text": "Save", "style": { "classes": "btn btn-primary btn-sm" } },
                "events": {
                  "component": {
                    "onActionPerformed": {
                      "type": "script",
                      "scope": "G",
                      "config": {
                        "script": "\tmode = self.view.params.mode\n\tdraft = self.view.custom.editDraft.get(\"meta\", {}) if self.view.custom.editDraft else {}\n\tif mode == \"create\":\n\t\tresult = BlueRidge.Oee.DowntimeReasonCode.add(draft)\n\t\tBlueRidge.Common.Ui.notifyResult(result, \"Downtime code created\")\n\telse:\n\t\tresult = BlueRidge.Oee.DowntimeReasonCode.update(draft)\n\t\tBlueRidge.Common.Ui.notifyResult(result, \"Downtime code updated\")\n\tif result and result.get(\"Status\"):\n\t\tsystem.perspective.sendMessage(\"downtimeCodesRefresh\", scope=\"page\")\n\t\tsystem.perspective.closePopup(id=\"mpp-downtime-code-editor\")"
                      }
                    }
                  }
                }
              }
            ]
          }
        ]
      }
    ],
    "scripts": {
      "messageHandlers": [
        {
          "messageType": "confirmUnsavedResult",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\taction = payload.get(\"action\") if payload else None\n\tif action == \"save\":\n\t\tmode = self.view.params.mode\n\t\tdraft = self.view.custom.editDraft.get(\"meta\", {}) if self.view.custom.editDraft else {}\n\t\tif mode == \"create\":\n\t\t\tresult = BlueRidge.Oee.DowntimeReasonCode.add(draft)\n\t\telse:\n\t\t\tresult = BlueRidge.Oee.DowntimeReasonCode.update(draft)\n\t\tBlueRidge.Common.Ui.notifyResult(result, \"Downtime code saved\")\n\t\tif result and result.get(\"Status\"):\n\t\t\tsystem.perspective.sendMessage(\"downtimeCodesRefresh\", scope=\"page\")\n\t\t\tsystem.perspective.closePopup(id=\"mpp-downtime-code-editor\")\n\telif action == \"discard\":\n\t\tsystem.perspective.closePopup(id=\"mpp-downtime-code-editor\")"
        }
      ]
    }
  }
}
```

- [ ] **Step 3: Write `resource.json`**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"]
}
```

- [ ] **Step 4: Trigger gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Verify in Designer**

User actions:
1. Project → Update Project
2. Open `BlueRidge/Components/Popups/DowntimeCodeEditor` — confirm parses cleanly, no Designer NPE
3. Right-click the view → Preview View. Set `mode` param to `"create"`. Confirm all form fields render. Type into Code — confirm dirty indicator appears.
4. Close preview.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DowntimeCodeEditor/
git commit -m "feat(oee-view): DowntimeCodeEditor popup (create + update + deprecate)"
```

---

## Task 8: Wire `DowntimeCodeRow` component — open editor on click

**Prerequisite:** **The user MUST close the `DowntimeCodeRow` view's tab in Designer before this task starts.** File-edit conflicts with an open tab will clobber the file or get overwritten on next Designer save. Ask the user to confirm closed-tab state before proceeding.

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DowntimeCodeRow/view.json`

- [ ] **Step 1: Confirm tab is closed**

Ask user: "Is the `DowntimeCodeRow` view's tab closed in Designer? (yes/no)" — if no, ask them to close it, then continue.

- [ ] **Step 2: Read current `view.json`**

Read the file to understand the existing component tree — especially the Edit button's component name and current event handlers (if any).

- [ ] **Step 3: Add `id` param to the row**

In `view.json`'s `params` block, add `"id": null` so the row knows which downtime code it represents. Update `propConfig.params.id` with `{ "paramDirection": "input", "persistent": true }`.

- [ ] **Step 4: Wire the Edit button's `onActionPerformed`**

Find the Edit button component (likely named `EditButton` or similar) and replace its `events.component.onActionPerformed` (or add it if missing) with:

```json
"events": {
  "component": {
    "onActionPerformed": {
      "type": "script",
      "scope": "C",
      "config": {
        "script": "\tsystem.perspective.openPopup(id=\"mpp-downtime-code-editor\", view=\"BlueRidge/Components/Popups/DowntimeCodeEditor\", modal=True, showCloseIcon=False, params={\"mode\": \"update\", \"editId\": self.view.params.id})"
      }
    }
  }
}
```

- [ ] **Step 5: Update `resource.json` `lastModification.timestamp`** to a fresh UTC ISO string and blank `lastModificationSignature` so Designer treats the file as changed.

- [ ] **Step 6: Trigger gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 7: Verify**

User reopens the view in Designer → confirm parses cleanly, Edit button's event panel shows the script.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DowntimeCodeRow/
git commit -m "feat(oee-view): wire DowntimeCodeRow Edit button to editor popup"
```

---

## Task 9: Wire `DowntimeCodes` parent view — live data + Add button + refresh handler

**Prerequisite:** **The user MUST close the `DowntimeCodes` view's tab in Designer before this task starts.** This is the most complex view edit; conflict risk is highest here.

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Oee/DowntimeCodes/view.json`

- [ ] **Step 1: Confirm tab is closed**

Ask user explicitly. Wait for confirmation.

- [ ] **Step 2: Read current `view.json`** end-to-end. Note especially:
- The structure of `view.custom.filter` (likely `{areaLocationId, downtimeReasonTypeId, searchText, includeDeprecated}`)
- The `view.custom.rows` hardcoded sample data block — this will be replaced
- The `view.custom.areaOptions` and `view.custom.reasonTypeOptions` hardcoded blocks — these will be replaced with `runScript` bindings
- The "+ Add Code" button's name and current event handler (if any)
- Whether a `refreshTick` custom prop already exists (used to force re-evaluation)

- [ ] **Step 3: Replace hardcoded options with runScript bindings**

In `propConfig`, add (or replace existing) bindings — using the `includeAll=True` form so filter dropdowns get the "All X" prepended option:

```json
"custom.areaOptions": {
  "binding": {
    "type": "expr",
    "config": { "expression": "runScript(\"BlueRidge.Location.Location.getAllAreas\", 0, true)" }
  }
},
"custom.reasonTypeOptions": {
  "binding": {
    "type": "expr",
    "config": { "expression": "runScript(\"BlueRidge.Oee.DowntimeReasonType.getForDropdown\", 0, true, true)" }
  }
}
```

Both helpers were defined in Tasks 3 and 5 with `includeAll` as an optional arg, so this works straight away — no back-edit needed. The DowntimeCodeEditor popup (Task 7) keeps the single-arg `runScript("...", 0)` form which gets defaults of `False, False` — correct for the editor where you want only real types/areas with no pseudo-options.

- [ ] **Step 4: Replace hardcoded `view.custom.rows` with runScript binding**

In `view.custom`, delete the hardcoded sample array and replace with `[]` default. In `propConfig`, add:

```json
"custom.rows": {
  "binding": {
    "type": "expr",
    "config": { "expression": "runScript(\"BlueRidge.Oee.DowntimeReasonCode.search\", 0, {view.custom.filter})" }
  }
}
```

This re-evaluates whenever any field of `view.custom.filter` changes (bidirectional bindings on the filter inputs trigger the re-evaluation).

- [ ] **Step 5: Wire "+ Add Code" button**

Find the "+ Add Code" button (likely named `AddCodeButton`). Replace its `events.component.onActionPerformed` with:

```json
"events": {
  "component": {
    "onActionPerformed": {
      "type": "script",
      "scope": "C",
      "config": {
        "script": "\tsystem.perspective.openPopup(id=\"mpp-downtime-code-editor\", view=\"BlueRidge/Components/Popups/DowntimeCodeEditor\", modal=True, showCloseIcon=False, params={\"mode\": \"create\", \"editId\": None})"
      }
    }
  }
}
```

- [ ] **Step 6: Add `id` param to the row instances rendered by the Flex Repeater**

Find the Flex Repeater (likely renders `BlueRidge/Components/DowntimeCodeRow` per row). In its `props.instances` binding's transform — or in its `instances` derived expression — ensure each instance dict includes `"id": <row.Id>` so the row's Edit-button handler (Task 8) has the id to pass to the popup.

If the Repeater builds instances via a script transform on `view.custom.rows`, ensure the transform maps `Id → id`. Example transform script (Python on the binding):

```python
def transform(self, value, quality, timestamp):
    return [
        {
            "id":          r.get("Id"),
            "code":        r.get("Code"),
            "description": r.get("Description"),
            "area":        r.get("AreaName"),
            "type":        r.get("TypeName") or "(Unassigned)",
            "excused":     bool(r.get("IsExcused")),
            "selected":    False
        }
        for r in (value or [])
    ]
```

The exact column aliases (`Id`/`Code`/`Description`/`AreaName`/`TypeName`/`IsExcused`) must match what the `_List` proc's SELECT returns — verify against Task 1 step 1 findings.

- [ ] **Step 7: Add `downtimeCodesRefresh` page-scoped message handler on root**

In `root.scripts.messageHandlers`, add:

```json
{
  "messageType": "downtimeCodesRefresh",
  "pageScope": true,
  "sessionScope": false,
  "viewScope": false,
  "script": "\tself.view.custom.filter = dict(self.view.custom.filter)"
}
```

The handler re-assigns `view.custom.filter` to a fresh shallow copy, which triggers the `custom.rows` runScript binding to re-evaluate. This is the refresh pulse the editor popup sends after Save/Deprecate.

- [ ] **Step 8: Update `resource.json` `lastModification.timestamp`** + blank `lastModificationSignature`.

- [ ] **Step 9: Trigger gateway scan**

```powershell
.\scan.ps1
```

- [ ] **Step 10: Verify in Designer**

User reopens the view → confirms parses cleanly, runs the view, confirms real rows show up (Step 11 covers full flow validation).

- [ ] **Step 11: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Oee/DowntimeCodes/
git commit -m "feat(oee-view): wire DowntimeCodes view to live data + add button"
```

---

## Task 10: End-to-end smoke test in Designer

**Files:** None modified — validation only.

- [ ] **Step 1: Browse — real data appears**

User opens the running app → navigate to Ops → Downtime Codes. Confirm:
- Rows appear (count > 0 if seed CSV has been bulk-loaded; otherwise zero rows is OK)
- Area + Reason Type filter dropdowns are populated
- Search input live-filters as text is typed

- [ ] **Step 2: Add flow**

Click "+ Add Code". Confirm editor popup opens in create mode. Fill:
- Code: `DC-9999`
- Description: `Smoke test`
- Area: any from dropdown
- Reason Type: any from dropdown
- Excused: checked

Click Save. Confirm:
- Success toast appears top-right
- Popup closes
- New row appears in the list (may need to clear search/filters)

- [ ] **Step 3: Edit flow**

Click the Edit button on the `DC-9999` row. Confirm editor opens in update mode:
- Code field is **readonly** showing `DC-9999`
- Other fields populated correctly
- Title says "Edit Downtime Code"
- Deprecate button is visible (bottom-left)

Change Description, click Save. Confirm toast + popup closes + row updates in list.

- [ ] **Step 4: Dirty + Close confirmation**

Open Edit on any row. Type into Description (now dirty). Click the X icon. Confirm:
- ConfirmUnsaved popup appears with 3 buttons
- Click Cancel → returns to the editor
- Click Discard & Close → both popups close, no save
- Reopen, type again, click Save & Close → mutation runs, toasts, both popups close, row updated

- [ ] **Step 5: Deprecate**

Open Edit on the `DC-9999` test row. Click Deprecate. Confirm:
- Success toast
- Popup closes
- Row is hidden from default list
- Toggle "Include deprecated" → row appears

- [ ] **Step 6: Server-side validation surfaces**

Click "+ Add Code". Set Code to `DC-9999` (now deprecated — Code should be unique even against deprecated, OR not, depending on proc semantics). Either way:
- If proc accepts → success
- If proc rejects → error toast with the proc's `Message`. Editor stays open. Acceptable.

Also try: Save with empty Description. Either client-side disables Save (if implemented), or server-side rejects with toast.

- [ ] **Step 7: Verify SQL tests still pass**

```powershell
.\Reset-DevDatabase.ps1
```

Expected: `937/937 tests passing` (no regressions — we touched no SQL).

- [ ] **Step 8: Update PROJECT_STATUS.md**

Add a Recent Change Narrative entry dated 2026-05-19 describing the downtime-codes wiring landing. Move the "audit pages addressing bug" pickup note to remain at the top (it's still pending separately).

- [ ] **Step 9: Final commit**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): downtime codes Ops view wired live -- editor + filter + refresh"
```

---

## Open follow-ups (after this plan completes)

1. **Bulk-load surface:** when seed CSV is loaded at cutover, run `Oee.DowntimeReasonCode_BulkLoadFromSeed` from Script Console (no UI button needed). Document the runbook step.
2. **Audit-pages `customMethods` addressing bug:** still pending separately (PROJECT_STATUS.md top item). This plan deliberately avoided customMethods, so it does not unblock or block the audit-pages fix.
3. **Polish:** if proc rejects duplicate codes against the deprecated set, decide whether to allow code reuse on Deprecate (filtered UNIQUE index pattern from `0014_locationattributedefinition_unique_active_name.sql` is a precedent).
