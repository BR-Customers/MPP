# Defect Codes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing `Quality/DefectCodes` mockup screen to live data with full CRUD via a shared Add/Edit modal popup.

**Architecture:**
- SQL: existing `Quality.DefectCode` table + 5 CRUD procs (Create, Update, Get, List, Deprecate) stand as-is. Only change: `List` re-orders by area-name then code. Add one generic `Location.Location_ListByTier` proc to populate the Area dropdown dynamically as the plant hierarchy fills in (FDS-08-016 deliberately allows the Area set to grow without UI churn).
- Ignition: 6 new NQs (5 quality + 1 location), one new entity script (`BlueRidge.Quality.DefectCode`), one extension function on `BlueRidge.Location.Location` (`listByTier`), one new popup view (`DefectCodeEditor`), wire-up changes to the existing list view + row sub-view.
- Reactive filtering — no Apply button. Area dropdown + Include-deprecated checkbox re-fire the query binding directly; SearchText narrows client-side on a derived binding (keeps SQL hits to one per filter change).
- Shared popup with `view.custom.mode` discriminator (`create` | `update`). +Add opens in `create`; per-row Edit opens in `update`. ConfirmUnsaved popup on Cancel/X when dirty (reuses `BlueRidge/Components/Popups/ConfirmUnsaved`).
- Code prefix auto-suggest on area-change in create mode only: derived from area Name (initials of multi-word names, full text if already a single ALL-CAPS acronym).
- Default sort: by area name (alpha), then code within area. SQL `ORDER BY` does the work; the flex-repeater renders rows in the order received.

**Tech Stack:** SQL Server 2022 stored procs; Ignition 8.3 Perspective file-based project; Jython script modules; named queries; flex-repeater with embedded `DefectCodeRow` sub-view; ConfirmUnsaved reusable popup pattern.

**Reference patterns (already in the codebase):**
- Mutation popup with editDraft/selected + dirty indicator + Save/Cancel/Deprecate: `BlueRidge/Components/Popups/LocationTypeEditor/view.json` and `project_mpp_plant_hierarchy_editor.md` memory
- ConfirmUnsaved popup wiring: `BlueRidge/Components/Popups/ConfirmUnsaved/view.json` and `project_mpp_confirm_unsaved_pattern.md` memory
- Entity-script shape via Common.Db helpers: `ignition-context-pack/03_script_python.md`
- NQ v2 schema + Designer sqlType enum: `ignition-context-pack/04_named_queries.md` + `feedback_ignition_nq_resource_schema.md` memory
- File-edit boundary for existing views: `feedback_ignition_view_edit_boundary.md` (close tab in Designer before file-editing)

---

## File Structure

**Modified:**
- `sql/migrations/repeatable/R__Quality_DefectCode_List.sql` — `ORDER BY` updated to `loc.Name, dc.Code`
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Quality/DefectCodes/view.json` — wire live bindings, +Add and Edit handlers, refresh trigger
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DefectCodeRow/view.json` — wire Edit button onClick to send `defectCodeEdit` page message
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py` — add `listByTier(tierCode)` helper

**Created:**
- `sql/migrations/repeatable/R__Location_Location_ListByTier.sql` — generic Location-by-tier read proc
- `sql/tests/01_location/110_Location_ListByTier.sql` — test file
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_List/{query.sql, resource.json}` — paged + filtered list
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Get/{query.sql, resource.json}` — single-row lookup
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Create/{query.sql, resource.json}` — mutation
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Update/{query.sql, resource.json}` — mutation
- `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Deprecate/{query.sql, resource.json}` — mutation
- `ignition/projects/MPP_Config/ignition/named-query/location/Location_ListByTier/{query.sql, resource.json}` — area dropdown source
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/__init__.py` and `Quality/code.py` (if needed — verify package directory creates correctly)
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/{code.py, resource.json}` — entity script
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DefectCodeEditor/{view.json, resource.json}` — new popup

---

## Task 1: SQL — Default sort by area, then code

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_DefectCode_List.sql:44`

- [ ] **Step 1: Verify current state**

Run:
```bash
grep -n "ORDER BY" sql/migrations/repeatable/R__Quality_DefectCode_List.sql
```
Expected output:
```
44:    ORDER BY dc.Code;
```

- [ ] **Step 2: Edit the ORDER BY clause**

Change line 44 from `ORDER BY dc.Code;` to `ORDER BY loc.Name, dc.Code;`. Use the Edit tool:

```
old_string: "    ORDER BY dc.Code;"
new_string: "    ORDER BY loc.Name, dc.Code;"
```

- [ ] **Step 3: Bump the version + change-log comment**

Edit the proc's Change Log block (~line 21-22) to add a new entry. Change:
```
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
```
to:
```
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-05-19 - 1.1 - ORDER BY changed from (Code) to (AreaName, Code) so the
--                       list view groups codes by area without client-side sorting
```

Also update the version header from `Version:     1.0` to `Version:     1.1`.

- [ ] **Step 4: Redeploy the proc**

```powershell
sqlcmd -S localhost -d MPP_MES_Dev -E -C -i "sql/migrations/repeatable/R__Quality_DefectCode_List.sql"
```

Expected: no error output.

- [ ] **Step 5: Verify new ordering**

```powershell
sqlcmd -S localhost -d MPP_MES_Dev -E -C -h -1 -Q "SET NOCOUNT ON; EXEC Quality.DefectCode_List;"
```

Expected: if any seed rows exist, they're ordered first by AreaName ascending, then Code ascending within each area. If the table is empty (likely until seed-load), an empty result set is the correct expected output.

- [ ] **Step 6: Run the existing test suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sql/tests/Run-Tests.ps1
```

Expected: `937 / 937 passed` (no new tests yet; existing tests don't assert order, so should still pass).

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_DefectCode_List.sql
git commit -m "fix(quality): DefectCode_List orders by AreaName, Code

So the Defect Codes list view groups codes by area without client-side
sorting. Version 1.1; existing tests don't assert order so 937/937 still pass."
```

---

## Task 2: SQL — `Location.Location_ListByTier` proc + tests

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Location_ListByTier.sql`
- Create: `sql/tests/01_location/110_Location_ListByTier.sql`

- [ ] **Step 1: Write the failing test file FIRST**

Create `sql/tests/01_location/110_Location_ListByTier.sql`:

```sql
-- =============================================
-- File:         01_location/110_Location_ListByTier.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-19
-- Description:
--   Tests for Location.Location_ListByTier.
--   Covers: returns matching rows, filters out deprecated, returns 0 for unknown tier.
--
--   Pre-conditions:
--     - Migration 0002 applied (LocationType seed has Tier 1..5 incl Area)
--     - Location.Location has at least one Area-tier row from seed_locations.sql
-- =============================================

EXEC test.BeginTestFile @FileName = N'01_location/110_Location_ListByTier.sql';
GO

-- =============================================
-- Setup: insert one Area-tier Location for deterministic assertions.
--   Uses an existing LocationTypeDefinition.Id for Area tier (ProductionArea = 3).
-- =============================================
DECLARE @ProductionAreaDefId BIGINT = (
    SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea'
);

DECLARE @ParentId BIGINT = (
    SELECT TOP 1 Id FROM Location.Location
     WHERE LocationTypeId = 2  -- Site tier
       AND DeprecatedAt IS NULL
);

INSERT INTO Location.Location (Code, Name, LocationTypeId, LocationTypeDefinitionId, ParentLocationId, SortOrder)
VALUES (N'TEST110-DC-AREA',  N'Test110 Die Cast Area',  3, @ProductionAreaDefId, @ParentId, 1);

INSERT INTO Location.Location (Code, Name, LocationTypeId, LocationTypeDefinitionId, ParentLocationId, SortOrder, DeprecatedAt)
VALUES (N'TEST110-DEPR-AREA', N'Test110 Deprecated Area', 3, @ProductionAreaDefId, @ParentId, 2, SYSUTCDATETIME());
GO

-- =============================================
-- Test 1: ListByTier('Area') returns the Test110 active area
-- =============================================
CREATE TABLE #ByTier1 (
    Id              BIGINT,
    Code            NVARCHAR(50),
    Name            NVARCHAR(200),
    LocationTypeId  BIGINT,
    LocationTypeDefinitionId BIGINT,
    ParentLocationId BIGINT,
    SortOrder       INT,
    DeprecatedAt    DATETIME2(3)
);

INSERT INTO #ByTier1
EXEC Location.Location_ListByTier @TierCode = N'Area';

DECLARE @Cnt1a INT = (SELECT COUNT(*) FROM #ByTier1 WHERE Code = N'TEST110-DC-AREA');
EXEC test.Assert_RowCount
    @TestName      = N'ListByTier(Area): active Test110 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Cnt1a;

-- Assert 1b: deprecated row is excluded
DECLARE @Cnt1b INT = (SELECT COUNT(*) FROM #ByTier1 WHERE Code = N'TEST110-DEPR-AREA');
EXEC test.Assert_RowCount
    @TestName      = N'ListByTier(Area): deprecated row excluded',
    @ExpectedCount = 0,
    @ActualCount   = @Cnt1b;

DROP TABLE #ByTier1;
GO

-- =============================================
-- Test 2: Unknown tier code returns 0 rows (no error)
-- =============================================
CREATE TABLE #ByTier2 (
    Id              BIGINT,
    Code            NVARCHAR(50),
    Name            NVARCHAR(200),
    LocationTypeId  BIGINT,
    LocationTypeDefinitionId BIGINT,
    ParentLocationId BIGINT,
    SortOrder       INT,
    DeprecatedAt    DATETIME2(3)
);

INSERT INTO #ByTier2
EXEC Location.Location_ListByTier @TierCode = N'BogusTier';

DECLARE @Cnt2 INT = (SELECT COUNT(*) FROM #ByTier2);
EXEC test.Assert_RowCount
    @TestName      = N'ListByTier(BogusTier): 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @Cnt2;

DROP TABLE #ByTier2;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run the test to confirm failure (proc doesn't exist yet)**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sql/tests/Run-Tests.ps1
```

Expected: the new file fails because `Location.Location_ListByTier` doesn't exist.

- [ ] **Step 3: Create the proc**

Create `sql/migrations/repeatable/R__Location_Location_ListByTier.sql`:

```sql
-- =============================================
-- Procedure:   Location.Location_ListByTier
-- Author:      Blue Ridge Automation
-- Created:     2026-05-19
-- Version:     1.0
--
-- Description:
--   Returns all active (non-deprecated) Locations whose LocationType
--   matches the given tier Code (e.g., 'Site', 'Area', 'WorkCenter',
--   'Cell', 'Workstation'). Generic read-side helper that backs any
--   tier-scoped dropdown (Areas for Defect Codes, Cells for Tool
--   Assignment, etc).
--
-- Parameters:
--   @TierCode NVARCHAR(50)  - Required. Matches Location.LocationType.Code.
--                              Returns empty if the tier code is unknown.
--
-- Result set:
--   Id, Code, Name, LocationTypeId, LocationTypeDefinitionId,
--   ParentLocationId, SortOrder, DeprecatedAt (always NULL given the
--   active filter — included for caller convenience).
--   Ordered by Name ASC.
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationType
--
-- Change Log:
--   2026-05-19 - 1.0 - Initial version (Defect Codes Area dropdown)
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_ListByTier
    @TierCode NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TierId BIGINT = (
        SELECT Id FROM Location.LocationType WHERE Code = @TierCode
    );

    IF @TierId IS NULL
        RETURN;

    SELECT
        loc.Id,
        loc.Code,
        loc.Name,
        loc.LocationTypeId,
        loc.LocationTypeDefinitionId,
        loc.ParentLocationId,
        loc.SortOrder,
        loc.DeprecatedAt
    FROM Location.Location loc
    WHERE loc.LocationTypeId  = @TierId
      AND loc.DeprecatedAt    IS NULL
    ORDER BY loc.Name;
END
GO
```

- [ ] **Step 4: Deploy the proc**

```powershell
sqlcmd -S localhost -d MPP_MES_Dev -E -C -i "sql/migrations/repeatable/R__Location_Location_ListByTier.sql"
```

Expected: no error output.

- [ ] **Step 5: Run the test suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sql/tests/Run-Tests.ps1
```

Expected: `940 / 940 passed` (3 new assertions added: Test 1a, 1b, 2).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Location_ListByTier.sql sql/tests/01_location/110_Location_ListByTier.sql
git commit -m "feat(location): generic Location_ListByTier read proc

Drives any tier-scoped dropdown. First consumer: Defect Codes Area
dropdown (FDS-08-017). Returns active Locations whose LocationType.Code
matches the input; empty for unknown tier code. 3 new tests; 940/940 pass."
```

---

## Task 3: Ignition — 6 new named queries

**Files (each NQ is one folder with `query.sql` + `resource.json`):**
- Create: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_List/`
- Create: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Get/`
- Create: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Create/`
- Create: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Update/`
- Create: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_Deprecate/`
- Create: `ignition/projects/MPP_Config/ignition/named-query/location/Location_ListByTier/`

> **Reference for the resource.json template:** clone the shape from any v2 NQ already in the project, e.g., `named-query/audit/FailureLog_List/resource.json`. sqlType codes per the Designer enum: BIGINT = 3, INTEGER = 2, BIT = 6, NVARCHAR = 7. See `ignition-context-pack/04_named_queries.md`.

- [ ] **Step 1: Create `quality/DefectCode_List`**

Path: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_List/query.sql`

```sql
EXEC Quality.DefectCode_List
    @IncludeDeprecated = :includeDeprecated,
    @AreaLocationId    = :areaLocationId
```

Path: `ignition/projects/MPP_Config/ignition/named-query/quality/DefectCode_List/resource.json`

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": ["query.sql"],
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
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-05-19T00:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "includeDeprecated", "sqlType": 6 },
      { "type": "Parameter", "identifier": "areaLocationId",    "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 2: Create `quality/DefectCode_Get`**

`query.sql`:
```sql
EXEC Quality.DefectCode_Get @Id = :id
```

`resource.json` (clone the List shape; one parameter):
```json
"parameters": [
  { "type": "Parameter", "identifier": "id", "sqlType": 3 }
]
```

- [ ] **Step 3: Create `quality/DefectCode_Create`**

`query.sql`:
```sql
EXEC Quality.DefectCode_Create
    @Code           = :code,
    @Description    = :description,
    @AreaLocationId = :areaLocationId,
    @IsExcused      = :isExcused,
    @AppUserId      = :appUserId
```

`resource.json` parameters block:
```json
"parameters": [
  { "type": "Parameter", "identifier": "code",           "sqlType": 7 },
  { "type": "Parameter", "identifier": "description",    "sqlType": 7 },
  { "type": "Parameter", "identifier": "areaLocationId", "sqlType": 3 },
  { "type": "Parameter", "identifier": "isExcused",      "sqlType": 6 },
  { "type": "Parameter", "identifier": "appUserId",      "sqlType": 3 }
]
```

Note: this proc emits a SELECT status row (Status/Message/NewId) so `type` stays `"Query"` (not `"UpdateQuery"`) — see `ignition-context-pack/04_named_queries.md` for why.

- [ ] **Step 4: Create `quality/DefectCode_Update`**

`query.sql`:
```sql
EXEC Quality.DefectCode_Update
    @Id             = :id,
    @Description    = :description,
    @AreaLocationId = :areaLocationId,
    @IsExcused      = :isExcused,
    @AppUserId      = :appUserId
```

`resource.json` parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id",             "sqlType": 3 },
  { "type": "Parameter", "identifier": "description",    "sqlType": 7 },
  { "type": "Parameter", "identifier": "areaLocationId", "sqlType": 3 },
  { "type": "Parameter", "identifier": "isExcused",      "sqlType": 6 },
  { "type": "Parameter", "identifier": "appUserId",      "sqlType": 3 }
]
```

- [ ] **Step 5: Create `quality/DefectCode_Deprecate`**

`query.sql`:
```sql
EXEC Quality.DefectCode_Deprecate
    @Id        = :id,
    @AppUserId = :appUserId
```

`resource.json` parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id",        "sqlType": 3 },
  { "type": "Parameter", "identifier": "appUserId", "sqlType": 3 }
]
```

- [ ] **Step 6: Create `location/Location_ListByTier`**

`query.sql`:
```sql
EXEC Location.Location_ListByTier @TierCode = :tierCode
```

`resource.json` parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "tierCode", "sqlType": 7 }
]
```

- [ ] **Step 7: Run gateway scan**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1
```

Expected: `lastScanDuration` reported, no error.

- [ ] **Step 8: Open Designer to verify NQs load without NPE**

Open each new NQ in Designer's Named Query editor. If any throws an NPE on open, the resource.json `version` is likely 1 instead of 2 — see `feedback_ignition_nq_resource_schema.md`. Fix and re-scan.

- [ ] **Step 9: Smoke-test execution via Designer Script Console**

In Script Console:
```python
system.db.runNamedQuery("quality/DefectCode_List", {"includeDeprecated": False, "areaLocationId": None})
```
Expected: a Dataset (may be empty if no codes seeded).

```python
system.db.runNamedQuery("location/Location_ListByTier", {"tierCode": "Area"})
```
Expected: a Dataset with whatever Area-tier locations exist (likely empty pre-seed).

- [ ] **Step 10: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/quality/ ignition/projects/MPP_Config/ignition/named-query/location/Location_ListByTier/
git commit -m "feat(quality, location): named queries for DefectCode CRUD + tier-scoped Locations

5 quality NQs (List/Get/Create/Update/Deprecate) + 1 location NQ
(Location_ListByTier). v2 schema; Designer-canonical sqlType enum;
BIT=6, NVARCHAR=7, BIGINT=3."
```

---

## Task 4: Entity script — `BlueRidge.Quality.DefectCode`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/resource.json`

- [ ] **Step 1: Verify package shape**

Check whether `script-python/BlueRidge/Quality/` directory already exists:
```bash
ls ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/ 2>/dev/null
```

If it doesn't exist, no action needed — Ignition creates the package implicitly when the first leaf module folder is added. The `DefectCode/` folder + its files are the trigger.

- [ ] **Step 2: Create `resource.json`**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/resource.json`

```json
{
  "scope": "A",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["code.py"],
  "attributes": {
    "hintScope": 2,
    "lastModification": { "actor": "claude", "timestamp": "2026-05-19T00:00:00Z" }
  }
}
```

- [ ] **Step 3: Create `code.py`**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Quality.DefectCode
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read + mutation surface for the Defect Codes Configuration Tool
#   screen (FDS-08-016 / FDS-08-017). Routes every DB call through
#   BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   getAll(includeDeprecated=False, areaLocationId=None) -> list[dict]
#   getOne(defectCodeId) -> dict | None
#   add(data) -> {Status, Message, NewId}
#   update(data) -> {Status, Message}
#   deprecate(defectCodeId) -> {Status, Message}
#   derivePrefix(areaName) -> str    -- helper for Code auto-suggest
#   filterAndMapRows(allRows, searchText) -> list[dict]
#                                    -- helper for flex-repeater binding
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAll(includeDeprecated=False, areaLocationId=None):
    """List defect codes, optionally including deprecated and/or filtered
    by area. SQL ORDER BY guarantees (AreaName, Code)."""
    BlueRidge.Common.Util.log("includeDeprecated=%s areaLocationId=%s"
                              % (includeDeprecated, areaLocationId))
    try:
        return BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {
                "includeDeprecated": 1 if includeDeprecated else 0,
                "areaLocationId":    areaLocationId,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load defect codes", str(e), "error")
        return []


def getOne(defectCodeId):
    """Single-row lookup. Returns dict or None."""
    BlueRidge.Common.Util.log("defectCodeId=%s" % defectCodeId)
    if defectCodeId is None:
        return None
    return BlueRidge.Common.Db.execOne(
        "quality/DefectCode_Get",
        {"id": defectCodeId},
    )


def add(data):
    """Insert. data: {Code, Description, AreaLocationId, IsExcused}.
    Returns {Status, Message, NewId}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Create",
        {
            "code":           data.get("Code"),
            "description":    data.get("Description"),
            "areaLocationId": data.get("AreaLocationId"),
            "isExcused":      1 if data.get("IsExcused") else 0,
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update existing row. data: {Id, Description, AreaLocationId, IsExcused}.
    Code is immutable on update (per the underlying proc)."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Update",
        {
            "id":             data.get("Id"),
            "description":    data.get("Description"),
            "areaLocationId": data.get("AreaLocationId"),
            "isExcused":      1 if data.get("IsExcused") else 0,
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(defectCodeId):
    """Soft-delete. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("defectCodeId=%s" % defectCodeId)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Deprecate",
        {
            "id":        defectCodeId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def derivePrefix(areaName):
    """Code prefix suggestion from area name.
    - 'Die Cast'         -> 'DC-'
    - 'Machine Shop'     -> 'MS-'
    - 'HSP'              -> 'HSP-'  (single ALL-CAPS word kept whole)
    - 'Production Control' -> 'PC-'
    - '' or None         -> ''"""
    if not areaName:
        return ""
    words = areaName.strip().split()
    if not words:
        return ""
    if len(words) == 1 and words[0].isupper() and len(words[0]) <= 4:
        return words[0] + "-"
    prefix = "".join(w[0].upper() for w in words)
    return prefix + "-"


def filterAndMapRows(allRows, searchText):
    """Flex-repeater instances transform.

    Filters allRows by case-insensitive substring match on Code or
    Description against searchText. Maps DB column names to the
    DefectCodeRow view-param shape. Returns list[dict] ready for
    Repeater.props.instances.
    """
    allRows = _u(allRows) or []
    s = (_u(searchText) or "").strip().lower()
    out = []
    for r in allRows:
        code        = r.get("Code") or ""
        description = r.get("Description") or ""
        if s and s not in code.lower() and s not in description.lower():
            continue
        out.append({
            "id":             r.get("Id"),
            "code":           code,
            "description":    description,
            "area":           r.get("AreaName") or "",
            "areaLocationId": r.get("AreaLocationId"),
            "excused":        bool(r.get("IsExcused")),
            "selected":       False,
        })
    return out
```

- [ ] **Step 4: Run gateway scan**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1
```

- [ ] **Step 5: Smoke-test in Designer Script Console**

```python
BlueRidge.Quality.DefectCode.getAll()
```
Expected: `[]` (or a list — likely empty pre-seed).

```python
BlueRidge.Quality.DefectCode.derivePrefix("Die Cast")
```
Expected: `'DC-'`

```python
BlueRidge.Quality.DefectCode.derivePrefix("HSP")
```
Expected: `'HSP-'`

```python
BlueRidge.Quality.DefectCode.filterAndMapRows(
    [{"Id": 1, "Code": "DC-100", "Description": "Porosity", "AreaName": "Die Cast",
      "AreaLocationId": 5, "IsExcused": False}],
    "poro")
```
Expected: a single-element list with `code='DC-100'`, `description='Porosity'`, etc.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/DefectCode/
git commit -m "feat(quality): BlueRidge.Quality.DefectCode entity script

Standard CRUD surface (getAll/getOne/add/update/deprecate) routed
through Common.Db. Helpers: derivePrefix (area-name -> Code prefix)
and filterAndMapRows (client-side search + DB-to-view shape mapping
for the flex-repeater)."
```

---

## Task 5: Entity script — Extend `BlueRidge.Location.Location` with `listByTier`

**Files:**
- Modify: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py`

- [ ] **Step 1: Read the existing module to find a good insertion point**

Read the file. Locate any existing read-side function (e.g., `getAll`, `getOne`) and add `listByTier` next to it for thematic grouping.

- [ ] **Step 2: Add the `listByTier` function**

Append (or insert in the read-side block):

```python
def listByTier(tierCode):
    """Returns active Locations whose LocationType.Code matches tierCode.
    Used by tier-scoped dropdowns (Area dropdown on Defect Codes,
    Cell dropdown on Tool Assignment, etc.).

    Args:
        tierCode (str): one of 'Enterprise', 'Site', 'Area', 'WorkCenter',
                         'Cell', 'Workstation' (per Location.LocationType seed).

    Returns:
        list[dict]: rows with Id, Code, Name, LocationTypeId,
                    LocationTypeDefinitionId, ParentLocationId, SortOrder.
                    Empty if tierCode is unknown.
    """
    BlueRidge.Common.Util.log("tierCode=%s" % tierCode)
    if not tierCode:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "location/Location_ListByTier",
            {"tierCode": tierCode},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("listByTier failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load locations", str(e), "error")
        return []
```

- [ ] **Step 3: Run gateway scan**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1
```

- [ ] **Step 4: Smoke-test in Designer Script Console**

```python
BlueRidge.Location.Location.listByTier("Area")
```
Expected: a list — likely empty if no Area-tier locations seeded yet, but should NOT error.

```python
BlueRidge.Location.Location.listByTier("BogusTier")
```
Expected: `[]`

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py
git commit -m "feat(location): BlueRidge.Location.Location.listByTier helper

Tier-scoped read used by dropdowns. First consumer: Defect Codes
Area dropdown. Returns active locations whose LocationType.Code
matches the input."
```

---

## Task 6: Create `DefectCodeEditor` popup view

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DefectCodeEditor/view.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DefectCodeEditor/resource.json`

This is a NEW view (no Designer cache to fight) so file-based authoring is the right path.

- [ ] **Step 1: Create `resource.json`**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json", "thumbnail.png"],
  "attributes": {
    "lastModification": { "actor": "claude", "timestamp": "2026-05-19T00:00:00Z" }
  }
}
```

- [ ] **Step 2: Create `view.json` skeleton with custom state + params**

The view receives `mode` and (in update mode) `defectCodeId` as params. On startup it loads the row (if update mode) and seeds `selected` + `editDraft`. The Area dropdown source is loaded from `BlueRidge.Location.Location.listByTier('Area')`.

```json
{
  "custom": {
    "mode":     "create",
    "selected": { "Id": null, "Code": "", "Description": "", "AreaLocationId": null, "IsExcused": false },
    "editDraft":{ "Id": null, "Code": "", "Description": "", "AreaLocationId": null, "IsExcused": false },
    "areas":    [],
    "_initFired": false
  },
  "params": {
    "mode":         "create",
    "defectCodeId": null
  },
  "propConfig": {
    "params.mode":         { "paramDirection": "input" },
    "params.defectCodeId": { "paramDirection": "input" },
    "custom.areas": {
      "binding": {
        "type": "expr",
        "config": { "expression": "runScript(\"BlueRidge.Location.Location.listByTier\", 0, \"Area\")" },
        "transforms": [
          {
            "type": "script",
            "code": "\treturn [{\"label\": r.get(\"Name\"), \"value\": r.get(\"Id\")} for r in (value or [])]"
          }
        ]
      }
    },
    "custom._initFired": {
      "binding": {
        "type": "expr",
        "config": { "expression": "now(0) != null" }
      },
      "onChange": {
        "enabled": true,
        "script": "\tif previousValue and previousValue.value != currentValue.value:\n\t\tself.rootContainer.loadIfUpdateMode()"
      }
    }
  },
  "props": {
    "defaultSize": { "width": 480, "height": 420 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "column",
      "style": {
        "background": "var(--mpp-surface-card)",
        "padding": "16px",
        "gap": "12px"
      }
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": { "name": "TitleRow" },
        "position": { "basis": "auto" },
        "props": { "direction": "row", "alignItems": "center", "style": { "gap": "8px" } },
        "children": [
          {
            "type": "ia.display.label",
            "meta": { "name": "Title" },
            "position": { "grow": 1 },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": { "expression": "if({view.custom.mode} = \"create\", \"Add Defect Code\", \"Edit \" + coalesce({view.custom.selected.Code}, \"\"))" }
                }
              }
            },
            "props": { "style": { "fontSize": "18px", "fontWeight": "600", "color": "var(--mpp-text-primary)" } }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "DirtyIndicator" },
            "position": { "basis": "auto" },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": { "expression": "if({view.custom.editDraft} != {view.custom.selected}, \"● Unsaved changes\", \"\")" }
                }
              }
            },
            "props": { "style": { "fontSize": "12px", "color": "var(--mpp-accent-90)" } }
          },
          {
            "type": "ia.input.button",
            "meta": { "name": "CloseIcon" },
            "position": { "basis": "auto" },
            "events": {
              "dom": {
                "onClick": {
                  "type": "script", "scope": "C",
                  "config": { "script": "\tself.view.rootContainer.handleClose()" }
                }
              }
            },
            "props": { "text": "×", "style": { "classes": "btn btn-icon" } }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "CodeField" },
        "position": { "basis": "auto" },
        "props": { "direction": "column", "style": { "gap": "4px" } },
        "children": [
          { "type": "ia.display.label", "meta": { "name": "CodeLabel" }, "position": { "basis": "auto" }, "props": { "text": "Code", "style": { "classes": "label-eyebrow" } } },
          {
            "type": "ia.input.text-field",
            "meta": { "name": "CodeInput" },
            "position": { "basis": "auto" },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "property",
                  "config": { "bidirectional": true, "path": "view.custom.editDraft.Code" }
                }
              },
              "props.enabled": {
                "binding": {
                  "type": "expr",
                  "config": { "expression": "{view.custom.mode} = \"create\"" }
                }
              }
            },
            "props": { "placeholder": "DC-0135", "style": { "classes": "text-input" } }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "DescriptionField" },
        "position": { "basis": "auto" },
        "props": { "direction": "column", "style": { "gap": "4px" } },
        "children": [
          { "type": "ia.display.label", "meta": { "name": "DescriptionLabel" }, "position": { "basis": "auto" }, "props": { "text": "Description", "style": { "classes": "label-eyebrow" } } },
          {
            "type": "ia.input.text-field",
            "meta": { "name": "DescriptionInput" },
            "position": { "basis": "auto" },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "property",
                  "config": { "bidirectional": true, "path": "view.custom.editDraft.Description" }
                }
              }
            },
            "props": { "placeholder": "Short description", "style": { "classes": "text-input" } }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "AreaField" },
        "position": { "basis": "auto" },
        "props": { "direction": "column", "style": { "gap": "4px" } },
        "children": [
          { "type": "ia.display.label", "meta": { "name": "AreaLabel" }, "position": { "basis": "auto" }, "props": { "text": "Area", "style": { "classes": "label-eyebrow" } } },
          {
            "type": "ia.input.dropdown",
            "meta": { "name": "AreaDropdown" },
            "position": { "basis": "auto" },
            "propConfig": {
              "props.options": { "binding": { "type": "property", "config": { "path": "view.custom.areas" } } },
              "props.value":   { "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.editDraft.AreaLocationId" } },
                                 "onChange": {
                                   "enabled": true,
                                   "script": "\tself.view.rootContainer.handleAreaChange(previousValue, currentValue)"
                                 } }
            },
            "props": { "style": { "classes": "select" } }
          }
        ]
      },
      {
        "type": "ia.input.checkbox",
        "meta": { "name": "IsExcusedCheckbox" },
        "position": { "basis": "auto" },
        "propConfig": {
          "props.selected": {
            "binding": {
              "type": "property",
              "config": { "bidirectional": true, "path": "view.custom.editDraft.IsExcused" }
            }
          }
        },
        "props": { "text": "Excused (does not affect OEE quality)", "style": { "classes": "checkbox" } }
      },
      {
        "type": "ia.display.label",
        "meta": { "name": "Spacer" },
        "position": { "grow": 1 },
        "props": { "text": "" }
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "FooterRow" },
        "position": { "basis": "auto" },
        "props": { "direction": "row", "alignItems": "center", "style": { "gap": "8px" } },
        "children": [
          {
            "type": "ia.input.button",
            "meta": { "name": "DeprecateButton" },
            "position": { "basis": "auto" },
            "propConfig": {
              "position.display": {
                "binding": {
                  "type": "expr",
                  "config": { "expression": "{view.custom.mode} = \"update\"" }
                }
              }
            },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script", "scope": "G",
                  "config": { "script": "\tself.view.rootContainer.handleDeprecate()" }
                }
              }
            },
            "props": { "text": "Deprecate", "style": { "classes": "btn btn-danger" } }
          },
          { "type": "ia.display.label", "meta": { "name": "FooterSpacer" }, "position": { "grow": 1 }, "props": { "text": "" } },
          {
            "type": "ia.input.button",
            "meta": { "name": "CancelButton" },
            "position": { "basis": "auto" },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script", "scope": "C",
                  "config": { "script": "\tself.view.rootContainer.handleClose()" }
                }
              }
            },
            "props": { "text": "Cancel", "style": { "classes": "btn" } }
          },
          {
            "type": "ia.input.button",
            "meta": { "name": "SaveButton" },
            "position": { "basis": "auto" },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script", "scope": "G",
                  "config": { "script": "\tself.view.rootContainer.handleSave()" }
                }
              }
            },
            "props": { "text": "Save", "style": { "classes": "btn btn-primary" } }
          }
        ]
      }
    ],
    "scripts": {
      "customMethods": [
        {
          "name": "loadIfUpdateMode",
          "params": [],
          "script": "\tself.view.custom.mode = self.view.params.mode or \"create\"\n\tif self.view.custom.mode != \"update\":\n\t\treturn\n\trow = BlueRidge.Quality.DefectCode.getOne(self.view.params.defectCodeId)\n\tif not row:\n\t\tBlueRidge.Common.Notify.toast(\"Defect code not found\", \"\", \"error\")\n\t\tsystem.perspective.closePopup(id=\"mpp-defect-code-editor\")\n\t\treturn\n\tloaded = {\n\t\t\"Id\":             row.get(\"Id\"),\n\t\t\"Code\":           row.get(\"Code\") or \"\",\n\t\t\"Description\":    row.get(\"Description\") or \"\",\n\t\t\"AreaLocationId\": row.get(\"AreaLocationId\"),\n\t\t\"IsExcused\":      bool(row.get(\"IsExcused\")),\n\t}\n\tself.view.custom.selected  = loaded\n\tself.view.custom.editDraft = dict(loaded)"
        },
        {
          "name": "handleAreaChange",
          "params": ["previousValue", "currentValue"],
          "script": "\t# Auto-suggest Code prefix on area change (create mode only,\n\t# and only when Code is empty or matches the previous area's prefix).\n\tif self.view.custom.mode != \"create\":\n\t\treturn\n\tnew_id = currentValue.value if currentValue else None\n\told_id = previousValue.value if previousValue else None\n\tareas = self.view.custom.areas or []\n\tdef name_for(area_id):\n\t\tfor a in areas:\n\t\t\tif a.get(\"value\") == area_id:\n\t\t\t\treturn a.get(\"label\")\n\t\treturn None\n\told_prefix = BlueRidge.Quality.DefectCode.derivePrefix(name_for(old_id))\n\tnew_prefix = BlueRidge.Quality.DefectCode.derivePrefix(name_for(new_id))\n\tcurrent_code = self.view.custom.editDraft.Code or \"\"\n\tif not current_code or current_code == old_prefix:\n\t\tself.view.custom.editDraft.Code = new_prefix"
        },
        {
          "name": "handleSave",
          "params": [],
          "script": "\tdraft = self.view.custom.editDraft\n\tif self.view.custom.mode == \"create\":\n\t\tresult = BlueRidge.Quality.DefectCode.add(draft)\n\t\tBlueRidge.Common.Ui.notifyResult(result, successTitle=\"Defect code created\")\n\telse:\n\t\tresult = BlueRidge.Quality.DefectCode.update(draft)\n\t\tBlueRidge.Common.Ui.notifyResult(result, successTitle=\"Defect code updated\")\n\tif result and result.get(\"Status\"):\n\t\tself.view.custom.selected = dict(self.view.custom.editDraft)\n\t\tsystem.perspective.sendMessage(\"defectCodeRefresh\", scope=\"page\")\n\t\tsystem.perspective.closePopup(id=\"mpp-defect-code-editor\")"
        },
        {
          "name": "handleDeprecate",
          "params": [],
          "script": "\tdef_id = self.view.custom.editDraft.Id\n\tif not def_id:\n\t\treturn\n\tresult = BlueRidge.Quality.DefectCode.deprecate(def_id)\n\tBlueRidge.Common.Ui.notifyResult(result, successTitle=\"Defect code deprecated\")\n\tif result and result.get(\"Status\"):\n\t\tsystem.perspective.sendMessage(\"defectCodeRefresh\", scope=\"page\")\n\t\tsystem.perspective.closePopup(id=\"mpp-defect-code-editor\")"
        },
        {
          "name": "handleClose",
          "params": [],
          "script": "\tif self.view.custom.editDraft == self.view.custom.selected:\n\t\tsystem.perspective.closePopup(id=\"mpp-defect-code-editor\")\n\t\treturn\n\tsystem.perspective.openPopup(\n\t\tid=\"mpp-confirm-unsaved\",\n\t\tview=\"BlueRidge/Components/Popups/ConfirmUnsaved\",\n\t\tmodal=True,\n\t\tshowCloseIcon=False,\n\t\tparams={\"title\": \"Unsaved Changes\",\n\t\t        \"message\": \"You have unsaved changes. Save before closing?\"})"
        }
      ],
      "messageHandlers": [
        {
          "messageType": "confirmUnsavedResult",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\taction = payload.get(\"action\") if payload else None\n\tif action == \"save\":\n\t\tself.handleSave()\n\telif action == \"discard\":\n\t\tsystem.perspective.closePopup(id=\"mpp-defect-code-editor\")"
        }
      ]
    }
  }
}
```

- [ ] **Step 3: Run gateway scan**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1
```

- [ ] **Step 4: Open the popup in Designer to verify it renders**

Open `BlueRidge/Components/Popups/DefectCodeEditor` in Designer. It should load without parse errors. The area dropdown may be empty pre-seed — that's expected.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DefectCodeEditor/
git commit -m "feat(quality): DefectCodeEditor popup view

Shared Add/Edit modal with view.custom.mode discriminator. Code field
disabled in update mode (immutable per proc). Area dropdown sourced
from Location_ListByTier; Code prefix auto-suggests on area change in
create mode. Save/Cancel/Deprecate buttons follow the LocationTypeEditor
pattern; ConfirmUnsaved popup on dirty close."
```

---

## Task 7: Wire the existing `Quality/DefectCodes` list view

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Quality/DefectCodes/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DefectCodeRow/view.json`

> **Editor boundary:** Close the `DefectCodes` and `DefectCodeRow` view tabs in Designer before file-editing (per `feedback_ignition_view_edit_boundary.md`). After all edits land, also blank `lastModificationSignature` and bump `lastModification.timestamp` on each resource.json so Designer reads fresh.

- [ ] **Step 1: Verify Designer tabs are closed**

Confirm with the user that the `Quality/DefectCodes` view and `Components/DefectCodeRow` view tabs are closed in Designer. (If unsure, ask.)

- [ ] **Step 2: Replace hardcoded `view.custom.rows` and `view.custom.areaOptions`**

In `DefectCodes/view.json`, replace the `custom` block at the top:

```json
"custom": {
  "filter": {
    "areaLocationId":    null,
    "searchText":        "",
    "includeDeprecated": false
  },
  "areaOptions": [],
  "allRows":     []
}
```

(Drop the hardcoded `rows` and the hardcoded `areaOptions` list. Drop `area` string field — replaced by `areaLocationId` BIGINT. Drop the per-row `selected` state — no longer needed.)

- [ ] **Step 3: Bind `custom.areaOptions` to live Area-tier locations**

In the `propConfig` block, add:

```json
"custom.areaOptions": {
  "binding": {
    "type": "expr",
    "config": { "expression": "runScript(\"BlueRidge.Location.Location.listByTier\", 0, \"Area\")" },
    "transforms": [
      {
        "type": "script",
        "code": "\treturn [{\"label\": \"All Areas\", \"value\": None}] + [{\"label\": r.get(\"Name\"), \"value\": r.get(\"Id\")} for r in (value or [])]"
      }
    ]
  }
}
```

The (All Areas) option binds to `None`, so when the filter is unset the proc's `@AreaLocationId IS NULL` branch fires (no area filter).

- [ ] **Step 4: Bind `custom.allRows` to the DefectCode_List NQ**

In the `propConfig` block, add:

```json
"custom.allRows": {
  "binding": {
    "type": "query",
    "config": {
      "queryPath":          "quality/DefectCode_List",
      "fallbackDelay":      2.5,
      "parameters": {
        "includeDeprecated": "{view.custom.filter.includeDeprecated}",
        "areaLocationId":    "{view.custom.filter.areaLocationId}"
      }
    },
    "transforms": [
      {
        "type": "script",
        "code": "\theaders = list(value.getColumnNames()) if value is not None else []\n\treturn [dict(zip(headers, row)) for row in (value or [])]"
      }
    ]
  }
}
```

The transform converts the Dataset into `list[dict]` so the flex-repeater transform can read named columns.

- [ ] **Step 5: Update the AreaDropdown binding to use `areaLocationId`**

Locate the AreaDropdown's `props.value` binding (currently bound to `view.custom.filter.area`). Change the path to `view.custom.filter.areaLocationId`:

```json
"props.value": { "binding": { "type": "property", "config": { "bidirectional": true, "path": "view.custom.filter.areaLocationId" } } }
```

- [ ] **Step 6: Wire the flex-repeater `instances` via filterAndMapRows**

Locate the `Rows` flex-repeater (currently `propConfig.props.instances` bound to `view.custom.rows`). Replace its binding with an expression that calls the helper:

```json
"props.instances": {
  "binding": {
    "type": "expr",
    "config": {
      "expression": "runScript(\"BlueRidge.Quality.DefectCode.filterAndMapRows\", 0, {view.custom.allRows}, {view.custom.filter.searchText})"
    }
  }
}
```

`runScript` re-evaluates whenever `allRows` or `searchText` changes, so the list filters reactively on every keystroke.

- [ ] **Step 7: Wire +Add Code button**

Locate the `AddCodeButton` (currently no events). Add:

```json
"events": {
  "component": {
    "onActionPerformed": {
      "type": "script", "scope": "C",
      "config": {
        "script": "\tsystem.perspective.openPopup(\n\t\tid=\"mpp-defect-code-editor\",\n\t\tview=\"BlueRidge/Components/Popups/DefectCodeEditor\",\n\t\tmodal=True,\n\t\tshowCloseIcon=False,\n\t\tparams={\"mode\": \"create\", \"defectCodeId\": None})"
      }
    }
  }
}
```

- [ ] **Step 8: Wire the page-scoped refresh message handler**

In the view's `scripts.messageHandlers` block (or add one if absent — root.scripts.messageHandlers), add a handler that re-runs the `allRows` query binding:

```json
"scripts": {
  "customMethods": [],
  "messageHandlers": [
    {
      "messageType": "defectCodeRefresh",
      "pageScope": true,
      "sessionScope": false,
      "viewScope": false,
      "script": "\tsystem.perspective.refreshBinding(\"view.custom.allRows\")"
    }
  ]
}
```

After Save / Deprecate in the editor, the editor sends `defectCodeRefresh` page-scoped; the list view picks it up and re-queries.

- [ ] **Step 9: Wire Edit button in `DefectCodeRow`**

In `DefectCodeRow/view.json`, the existing params block already has `code`, `description`, `area`, `excused`, `selected`. Add `id` and `areaLocationId` params:

```json
"params": {
  "id":             0,
  "code":           "",
  "description":    "",
  "area":           "",
  "areaLocationId": 0,
  "excused":        false,
  "selected":       false
},
"propConfig": {
  "params.id":             { "paramDirection": "input" },
  "params.code":           { "paramDirection": "input" },
  "params.description":    { "paramDirection": "input" },
  "params.area":           { "paramDirection": "input" },
  "params.areaLocationId": { "paramDirection": "input" },
  "params.excused":        { "paramDirection": "input" },
  "params.selected":       { "paramDirection": "input" }
}
```

Find the EditButton and add an `onActionPerformed` event:

```json
"events": {
  "component": {
    "onActionPerformed": {
      "type": "script", "scope": "C",
      "config": {
        "script": "\tsystem.perspective.openPopup(\n\t\tid=\"mpp-defect-code-editor\",\n\t\tview=\"BlueRidge/Components/Popups/DefectCodeEditor\",\n\t\tmodal=True,\n\t\tshowCloseIcon=False,\n\t\tparams={\"mode\": \"update\", \"defectCodeId\": self.view.params.id})"
      }
    }
  }
}
```

- [ ] **Step 10: Bump `lastModificationSignature` and timestamp on both resource.json files**

For each of:
- `BlueRidge/Views/Quality/DefectCodes/resource.json`
- `BlueRidge/Components/DefectCodeRow/resource.json`

Set `lastModificationSignature` to `""` and `lastModification.timestamp` to a fresh UTC ISO timestamp (use `(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")` to generate).

- [ ] **Step 11: Run gateway scan**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1
```

- [ ] **Step 12: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Quality/DefectCodes/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DefectCodeRow/
git commit -m "feat(quality): wire DefectCodes list view to live data

- view.custom.allRows bound to quality/DefectCode_List query with
  reactive params (areaLocationId, includeDeprecated)
- view.custom.areaOptions bound to Location_ListByTier(Area), prepended
  with (All Areas)=null sentinel
- Repeater.instances driven by runScript(filterAndMapRows, allRows,
  searchText) for client-side search without re-querying
- +Add Code opens DefectCodeEditor in create mode
- DefectCodeRow Edit button opens DefectCodeEditor in update mode
  with the row's id passed as a param
- defectCodeRefresh page message triggers refreshBinding(allRows)
  after editor Save/Deprecate"
```

---

## Task 8: End-to-end smoke test in Designer

No code in this task — just verification. The user runs the gateway, opens the page, and walks the flows.

- [ ] **Step 1: Confirm a few Area-tier locations exist for the test**

If the plant hierarchy is empty, manually add at least 2 Area-tier Locations via the Plant Hierarchy editor (e.g., "Die Cast" and "Machine Shop"). Without any areas, the dropdown will be empty and the Add flow can't proceed (Area is FK NOT NULL).

- [ ] **Step 2: Navigate to Quality → Defect Codes**

In a Perspective session, browse to the Defect Codes page. Expected: empty list (no codes seeded yet), filter sidebar visible with Area dropdown populated, search field, Include-deprecated checkbox.

- [ ] **Step 3: Add a code**

Click `+ Add Code`. Expected:
- Popup opens with title "Add Defect Code"
- Code field empty + enabled
- Area dropdown lists the seeded areas

Select Area = "Die Cast". Expected: Code field auto-fills with `DC-` (the prefix). Type `0135` after the prefix → Code = `DC-0135`. Fill Description = `Porosity`. Leave Excused unchecked. Click Save.

Expected:
- Green success toast: "Defect code created"
- Popup closes
- List view shows the new row at the top of the Die Cast section (sorted by area then code)

- [ ] **Step 4: Test the prefix auto-replace logic**

Click + Add Code again. Pick Die Cast → Code = `DC-`. Change area to Machine Shop. Expected: Code updates to `MS-` (because it matched the old prefix exactly). Now type `MS-0001` to override. Change area back to Die Cast. Expected: Code stays at `MS-0001` (not overwritten — doesn't match the new "Die Cast" prefix `DC-` either, since user has customized). Cancel without saving.

- [ ] **Step 5: Test edit**

On the row created in step 3, click Edit. Expected:
- Popup opens with title "Edit DC-0135"
- Code field shows `DC-0135` and is disabled
- Description shows `Porosity`
- Area shows `Die Cast`
- Excused checkbox unchecked

Change Description to `Porosity — Surface`. Click Save.

Expected:
- Green success toast: "Defect code updated"
- Popup closes
- List row updates with new description

- [ ] **Step 6: Test dirty-cancel flow**

Edit DC-0135 again. Toggle the Excused checkbox. Expected: "● Unsaved changes" appears next to title. Click Cancel.

Expected:
- ConfirmUnsaved popup opens with three buttons
- Click "Discard & Close" → editor closes, no changes persisted
- Re-open editor → Excused is still unchecked

- [ ] **Step 7: Test the search filter**

In the list view, type `por` in the Search field. Expected: list narrows to rows whose Code or Description contains "por" (case-insensitive). Clear search. Expected: list expands back.

- [ ] **Step 8: Test the area filter**

Add a second code in a different area (e.g., `MS-0001` Dimensional under Machine Shop). Pick the Area filter dropdown → Die Cast. Expected: only DC-* rows visible. Pick (All Areas). Expected: both rows visible.

- [ ] **Step 9: Test deprecate + include-deprecated toggle**

Edit DC-0135 → click Deprecate. Expected:
- Green toast: "Defect code deprecated"
- Editor closes
- Row disappears from list (Include-deprecated unchecked)

Tick Include-deprecated. Expected: DC-0135 reappears (visually it should display the same — no greyed-out treatment in current row design; that's a follow-up if needed).

- [ ] **Step 10: Report results**

Walk the checklist and report any failures back. If anything misbehaves, the gateway log is the first stop (Status → Diagnostics → Logs, filter to recent entries from `BlueRidge.Quality.DefectCode.*`).

---

## Self-Review Pass

**Spec coverage check** (against this conversation's design decisions):

| Decision | Task |
|---|---|
| Modal popup (not inline/side panel) | Task 6 |
| Area dropdown sources real plant Locations | Task 2 + 3.6 + 5 + 7.3 |
| Auto-suggest Code prefix on area change | Task 4 (`derivePrefix`) + Task 6 (`handleAreaChange`) |
| No bulk-seed UI | (out of scope — confirmed) |
| Default sort by area | Task 1 (SQL ORDER BY) |
| Flex-repeater (not table component) | Task 7.6 (instances binding via runScript) |
| Edit button opens same popup in edit mode | Task 7.9 + Task 6 (mode discriminator) |
| ConfirmUnsaved on Cancel when dirty | Task 6 (handleClose + confirmUnsavedResult handler) |

**Placeholder scan:** No TBDs / TODOs / "add appropriate error handling" / vague references found.

**Type/signature consistency check:**
- `derivePrefix(areaName)` — Task 4 defined, Task 6 calls with `name_for(old_id)` (returns Name string). ✓
- `filterAndMapRows(allRows, searchText)` — Task 4 returns list with keys `id/code/description/area/areaLocationId/excused/selected`. Task 7.6 (flex-repeater) passes to DefectCodeRow; Task 7.9 declares those same params on DefectCodeRow. ✓
- NQ `quality/DefectCode_Create` param names — `code, description, areaLocationId, isExcused, appUserId`. Task 4 `add()` passes the same dict keys. ✓
- Page message names — `defectCodeRefresh` (editor → list). Task 6 emits, Task 7.8 receives. ✓
- Popup id `mpp-defect-code-editor` — Task 6 self-closes, Task 7.7 opens, Task 7.9 opens. ✓
- View.custom shape for filter — `areaLocationId, searchText, includeDeprecated`. Task 7.2 declares; Tasks 7.5/7.6 reference. ✓

No issues found.
