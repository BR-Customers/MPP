# LOT Detail View (Arc 2 Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the polymorphic **LOT Detail** Perspective view, scoped to what the shipped Phase 2 SQL backs, with one small new read proc.

**Architecture:** SQL-first. One new read proc (`LotPause_GetByLot`) + a two-column extension to `Lot_Get`, each test-driven against the existing `0021_PlantFloor_Lot_Lifecycle` harness. Then four thin Core NQs wrap the existing Phase 2 read procs, four entity methods wrap the NQs, and one MPP view renders the mockup's `lot/detail` screen — History / Genealogy / Paused-at live, Linked Container + Hold/Scrap stubbed as later-phase.

**Tech Stack:** SQL Server 2022 (`CREATE OR ALTER` repeatable procs, `test.Assert_*` harness, `Run-Tests.ps1`), Ignition 8.3 file-based Perspective (Core NQs + `BlueRidge.*` entity scripts, MPP view), `scan.ps1`.

**Design source of truth:** `mockup/plantFloor.html` → `section[data-route="lot/detail"]`. Spec: `docs/superpowers/specs/2026-06-12-arc2-phase2-lot-detail-view-design.md`.

**Conventions to read first:** `ignition-context-pack/03_script_python.md`, `04_named_queries.md`, `07_conventions_and_antipatterns.md`; CLAUDE.md (SQL design, FDS-11-011 no-OUTPUT, predeclare-bound-custom-props, test teardown FK order). Reference plant-floor views: `BlueRidge/Views/ShopFloor/HomeRouter`, `.../InitialsEntry`.

---

## File Structure

**SQL (create):**
- `sql/migrations/repeatable/R__Lots_LotPause_GetByLot.sql` — new read proc.
- `sql/tests/0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql` — its tests.
- `sql/tests/0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql` — asserts extended `Lot_Get` shape.

**SQL (modify):**
- `sql/migrations/repeatable/R__Lots_Lot_Get.sql` — add `ToolCode` + `ToolCavityNumber` (LEFT JOINs).

**Ignition — Core (create):** four NQ folders under `ignition/projects/Core/ignition/named-query/lots/`:
- `Lot_GetParents/`, `Lot_GetChildren/`, `Lot_GetAttributeHistory/`, `LotPause_GetByLot/` (each `query.sql` + `resource.json`).

**Ignition — Core (modify):**
- `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` — add `getParents`, `getChildren`, `getHistory`, `getPauses`.

**Ignition — MPP (create):**
- `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/LotDetail/view.json` + `resource.json`.

**Ignition — MPP (modify):**
- `ignition/projects/MPP/.../page-config/config.json` — add `/shop-floor/lot-detail` route.

---

## Task 1: `LotPause_GetByLot` read proc

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_LotPause_GetByLot.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql`

Mirrors `R__Lots_LotPause_GetByLocation.sql` but keys on `@LotId` and returns pauses across **all** Locations for one LOT (a LOT may be paused at multiple Cells), adding `LocationName`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql`:

```sql
-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql
-- Author:       Blue Ridge Automation
-- Description:  Tests for Lots.LotPause_GetByLot(@LotId) -- the LOT Detail
--               "Paused-at" tab read. Returns OPEN pauses for one LOT across all
--               Locations, oldest-first. READ proc: no status row; empty set = none.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql';
GO

-- ---- fixtures: one LOT, two distinct active Cells ----
IF OBJECT_ID(N'tempdb..#GBLFix') IS NOT NULL DROP TABLE #GBLFix;
CREATE TABLE #GBLFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT, @CellB BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;
SELECT TOP 1 @CellB = Id FROM Location.Location
WHERE Id <> @CellA AND DeprecatedAt IS NULL ORDER BY Id;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 30, @AppUserId = 1;
INSERT INTO #GBLFix (Tag, Val) SELECT N'Lot', NewId FROM @cr;
INSERT INTO #GBLFix (Tag, Val) VALUES (N'CellA', @CellA), (N'CellB', @CellB);
GO

-- Test 1: a LOT paused at two Cells returns both rows, oldest-first
DECLARE @Lot BIGINT = (SELECT Val FROM #GBLFix WHERE Tag = N'Lot');
DECLARE @CellA BIGINT = (SELECT Val FROM #GBLFix WHERE Tag = N'CellA');
DECLARE @CellB BIGINT = (SELECT Val FROM #GBLFix WHERE Tag = N'CellB');

DECLARE @p1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p1 EXEC Lots.LotPause_Place @LotId = @Lot, @LocationId = @CellA, @AppUserId = 1;
-- force CellA's pause older so ordering is deterministic
UPDATE Lots.PauseEvent SET PausedAt = DATEADD(SECOND, -30, SYSUTCDATETIME())
    WHERE LotId = @Lot AND LocationId = @CellA AND ResumedAt IS NULL;
DECLARE @p2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p2 EXEC Lots.LotPause_Place @LotId = @Lot, @LocationId = @CellB, @AppUserId = 1;

CREATE TABLE #gbl (PauseEventId BIGINT, LotId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200),
                   PausedAt DATETIME2(3), PausedByUserId BIGINT, PausedReason NVARCHAR(500));
INSERT INTO #gbl EXEC Lots.LotPause_GetByLot @LotId = @Lot;

DECLARE @n INT = (SELECT COUNT(*) FROM #gbl);
EXEC test.Assert_RowCount @TestName = N'[GetByLot] LOT paused at 2 Cells returns 2 rows',
    @ExpectedCount = 2, @ActualCount = @n;

DECLARE @firstLoc BIGINT = (SELECT TOP 1 LocationId FROM #gbl ORDER BY PausedAt ASC);
DECLARE @firstLocStr NVARCHAR(20) = CAST(@firstLoc AS NVARCHAR(20));
DECLARE @cellAStr NVARCHAR(20) = CAST(@CellA AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[GetByLot] oldest-first (CellA leads)',
    @Expected = @cellAStr, @Actual = @firstLocStr;
DROP TABLE #gbl;
GO

-- Test 2: resuming one pause drops it from the list
DECLARE @Lot BIGINT = (SELECT Val FROM #GBLFix WHERE Tag = N'Lot');
DECLARE @CellA BIGINT = (SELECT Val FROM #GBLFix WHERE Tag = N'CellA');
DECLARE @paId BIGINT = (SELECT Id FROM Lots.PauseEvent
    WHERE LotId = @Lot AND LocationId = @CellA AND ResumedAt IS NULL);
DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rr EXEC Lots.LotPause_Resume @PauseEventId = @paId, @AppUserId = 1;

CREATE TABLE #gbl2 (PauseEventId BIGINT, LotId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200),
                    PausedAt DATETIME2(3), PausedByUserId BIGINT, PausedReason NVARCHAR(500));
INSERT INTO #gbl2 EXEC Lots.LotPause_GetByLot @LotId = @Lot;
DECLARE @n2 INT = (SELECT COUNT(*) FROM #gbl2);
DROP TABLE #gbl2;
EXEC test.Assert_RowCount @TestName = N'[GetByLot] one open pause remains after resume',
    @ExpectedCount = 1, @ActualCount = @n2;
GO

-- ---- cleanup (FK-safe: closure before LOTs) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Val FROM #GBLFix WHERE Tag = N'Lot';
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Lots.PauseEvent pe ON pe.Id = ol.EntityId
    INNER JOIN @ids x ON x.Id = pe.LotId
    WHERE ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'PauseEvent');
DELETE FROM Lots.PauseEvent WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#GBLFix') IS NOT NULL DROP TABLE #GBLFix;
GO
```

- [ ] **Step 2: Run the suite, verify this file fails**

Run: `pwsh ./sql/Run-Tests.ps1 -Filter 0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql`
Expected: FAIL — `Could not find stored procedure 'Lots.LotPause_GetByLot'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_LotPause_GetByLot.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_LotPause_GetByLot.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-12
-- Version:     1.0
-- Description: READ proc backing the LOT Detail "Paused-at" tab. Returns the OPEN
--              pauses for one LOT across ALL Locations (a LOT may be paused at
--              multiple Cells), oldest-first. READ proc: no @Status/@Message, no
--              status row, one result set; empty set = no open pauses.
--              Sibling of Lots.LotPause_GetByLocation, keyed by LotId + LocationName.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotPause_GetByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT pe.Id              AS PauseEventId,
           pe.LotId           AS LotId,
           pe.LocationId      AS LocationId,
           loc.Name           AS LocationName,
           pe.PausedAt        AS PausedAt,
           pe.PausedByUserId  AS PausedByUserId,
           pe.PausedReason    AS PausedReason
    FROM Lots.PauseEvent pe
    INNER JOIN Location.Location loc ON loc.Id = pe.LocationId
    WHERE pe.LotId = @LotId
      AND pe.ResumedAt IS NULL
    ORDER BY pe.PausedAt ASC, pe.Id ASC;
END;
GO
```

- [ ] **Step 4: Run the suite, verify green**

Run: `pwsh ./sql/Run-Tests.ps1 -Filter 0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql`
Expected: PASS (3 assertions). Then run the full suite to confirm no regression: `pwsh ./sql/Run-Tests.ps1` → all green (was 1449/1449; now +3).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_LotPause_GetByLot.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql
git commit -m "feat(sql): LotPause_GetByLot - per-LOT open-pause read for LOT Detail Paused-at tab"
```

---

## Task 2: Extend `Lot_Get` with Tool code + Cavity number

The polymorphic header shows the Tool **code** ("DC-042") and Cavity **number**, but `Lot_Get` returns only `ToolId`/`ToolCavityId`. Add two LEFT JOINs (LEFT because both are NULL for non-die-cast LOTs — the whole point of the polymorphic view).

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Get.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql`

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql`. The INSERT-EXEC into a temp table that declares `ToolCode`/`ToolCavityNumber` fails with a column-count mismatch until the proc returns them — that is the shape assertion.

```sql
-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql
-- Description:  LOT Detail relies on Lot_Get returning resolved ToolCode +
--               ToolCavityNumber (polymorphic header). Asserts the proc's result
--               shape includes them and they are NULL for a non-die-cast LOT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql';
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 30, @AppUserId = 1;
DECLARE @Lot BIGINT = (SELECT NewId FROM @cr);

-- Temp table includes the two NEW columns. If Lot_Get doesn't SELECT them,
-- the INSERT-EXEC throws a column mismatch and the file fails.
CREATE TABLE #lg (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, Weight DECIMAL(18,4), WeightUomId BIGINT,
    ToolId BIGINT, ToolCavityId BIGINT, VendorLotNumber NVARCHAR(100),
    MinSerialNumber BIGINT, MaxSerialNumber BIGINT, ParentLotId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT,
    CreatedByUserId BIGINT, CreatedAtTerminalId BIGINT, CreatedAt DATETIME2(3),
    UpdatedAt DATETIME2(3), UpdatedByUserId BIGINT, RowVersion BIGINT,
    ItemPartNumber NVARCHAR(50), LotOriginTypeCode NVARCHAR(30),
    LotStatusCode NVARCHAR(30), LotStatusName NVARCHAR(100), CurrentLocationName NVARCHAR(200),
    ToolCode NVARCHAR(50), ToolCavityNumber NVARCHAR(20)
);
INSERT INTO #lg EXEC Lots.Lot_Get @LotId = @Lot, @LotName = NULL;

DECLARE @n INT = (SELECT COUNT(*) FROM #lg);
EXEC test.Assert_RowCount @TestName = N'[LotGet] returns the LOT with extended shape',
    @ExpectedCount = 1, @ActualCount = @n;

-- Received LOT -> Tool columns NULL
DECLARE @toolNull NVARCHAR(10) = (SELECT CASE WHEN ToolCode IS NULL THEN N'1' ELSE N'0' END FROM #lg);
EXEC test.Assert_IsEqual @TestName = N'[LotGet] ToolCode NULL for non-die-cast LOT',
    @Expected = N'1', @Actual = @toolNull;
DROP TABLE #lg;

-- cleanup (FK-safe)
DECLARE @ids TABLE (Id BIGINT); INSERT INTO @ids VALUES (@Lot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
GO
```

- [ ] **Step 2: Run, verify it fails**

Run: `pwsh ./sql/Run-Tests.ps1 -Filter 0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql`
Expected: FAIL — INSERT-EXEC column count mismatch (`ToolCode`/`ToolCavityNumber` not returned).

- [ ] **Step 3: Extend the proc**

In `sql/migrations/repeatable/R__Lots_Lot_Get.sql`, add the two resolved columns to the SELECT (after `CurrentLocationName`) and the two LEFT JOINs (after the `Location.Location` join):

```sql
        loc.Name           AS CurrentLocationName,
        t.Code             AS ToolCode,
        tc.CavityNumber    AS ToolCavityNumber
    FROM Lots.Lot l
    INNER JOIN Parts.Item            i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotOriginType    ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Lots.LotStatusCode    sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Location.Location     loc ON loc.Id = l.CurrentLocationId
    LEFT  JOIN Tools.Tool            t   ON t.Id   = l.ToolId
    LEFT  JOIN Tools.ToolCavity      tc  ON tc.Id  = l.ToolCavityId
```

(Drop the old trailing comma/line so `CurrentLocationName` now ends with a comma and `ToolCavityNumber` is the last column.)

- [ ] **Step 4: Run, verify green + no regression**

Run: `pwsh ./sql/Run-Tests.ps1 -Filter 0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql` → PASS.
Then `pwsh ./sql/Run-Tests.ps1` → full suite green (the existing `0020/050_Lot_Get_List.sql` uses named columns, so two extra columns don't break it; if it INSERT-EXECs a fixed-shape temp table, widen that temp table by the two trailing columns and re-run).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Get.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql
git commit -m "feat(sql): Lot_Get resolves ToolCode + ToolCavityNumber for polymorphic LOT Detail header"
```

---

## Task 3: Four Core Named Queries

Thin `EXEC` wrappers, one `@LotId` param each. Clone the shape of the existing `ignition/projects/Core/ignition/named-query/lots/Lot_Get/resource.json` (`scope:"DG"`, `version:2`, `type:"Query"`, `database:"MPP"`), reducing `parameters[]` to a single `lotId` (`sqlType:3`).

**Files (create):**
- `ignition/projects/Core/ignition/named-query/lots/Lot_GetParents/{query.sql,resource.json}`
- `ignition/projects/Core/ignition/named-query/lots/Lot_GetChildren/{query.sql,resource.json}`
- `ignition/projects/Core/ignition/named-query/lots/Lot_GetAttributeHistory/{query.sql,resource.json}`
- `ignition/projects/Core/ignition/named-query/lots/LotPause_GetByLot/{query.sql,resource.json}`

- [ ] **Step 1: Write the four `query.sql` files**

```sql
-- Lot_GetParents/query.sql
EXEC Lots.Lot_GetParents @LotId = :lotId
```
```sql
-- Lot_GetChildren/query.sql
EXEC Lots.Lot_GetChildren @LotId = :lotId
```
```sql
-- Lot_GetAttributeHistory/query.sql
EXEC Lots.Lot_GetAttributeHistory @LotId = :lotId
```
```sql
-- LotPause_GetByLot/query.sql
EXEC Lots.LotPause_GetByLot @LotId = :lotId
```

- [ ] **Step 2: Write the four `resource.json` files**

Identical for all four (single `lotId` param). Example — use this verbatim in each folder:

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
    "lastModification": { "actor": "claude", "timestamp": "2026-06-12T12:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "lotId", "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 3: Scan**

Run: `pwsh ./scan.ps1`
Expected: HTTP 200, no errors. (No gateway restart — scan re-reads NQs.)

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_GetParents ignition/projects/Core/ignition/named-query/lots/Lot_GetChildren ignition/projects/Core/ignition/named-query/lots/Lot_GetAttributeHistory ignition/projects/Core/ignition/named-query/lots/LotPause_GetByLot
git commit -m "feat(ignition): Core NQs wrapping Phase 2 LOT genealogy/history/pause reads"
```

---

## Task 4: Entity methods on `BlueRidge.Lots.Lot`

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`

- [ ] **Step 1: Add the four read methods**

Append after `assertNotBlocked` (mirror the existing `list()` thin-wrapper style — all reads, `execList`):

```python
def getParents(lotId):
    """Direct parents of a LOT (one-hop genealogy edges). Returns list[dict]."""
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetParents", {"lotId": lotId})


def getChildren(lotId):
    """Direct children of a LOT (one-hop genealogy edges). Returns list[dict]."""
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetChildren", {"lotId": lotId})


def getHistory(lotId):
    """Attribute + status + movement history for a LOT, oldest-first.
       Returns list[dict] with EventAt / EventKind / Detail / ByUserId / ByUserName."""
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetAttributeHistory", {"lotId": lotId})


def getPauses(lotId):
    """Open pauses for a LOT across all Locations (the Paused-at tab). list[dict]."""
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/LotPause_GetByLot", {"lotId": lotId})
```

- [ ] **Step 2: Scan**

Run: `pwsh ./scan.ps1` → 200.

- [ ] **Step 3: Smoke each method in the Designer Script Console (Core scope)**

```python
print BlueRidge.Lots.Lot.getHistory(<a real lotId from MPP_MES_Dev>)
print BlueRidge.Lots.Lot.getParents(<id>)
print BlueRidge.Lots.Lot.getChildren(<id>)
print BlueRidge.Lots.Lot.getPauses(<id>)
```
Expected: each returns a list (possibly empty) with no exception. (Script Console runs in Core scope, where these NQs live — see `project_mpp_nq_core_topology`.)

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
git commit -m "feat(ignition): Lot entity read methods for LOT Detail (parents/children/history/pauses)"
```

---

## Task 5: LOT Detail view + route

Author the view faithful to `mockup/plantFloor.html` `section[data-route="lot/detail"]`. This is a **read-only** screen — no `editDraft`, no mutations. Mirror plant-floor view conventions from `BlueRidge/Views/ShopFloor/HomeRouter` and `.../InitialsEntry` (header chrome, style classes, `events.system` lifecycle).

**Files:**
- Create: `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/LotDetail/{view.json,resource.json}`
- Modify: `ignition/projects/MPP/.../page-config/config.json`

### View structure (build to this)

- **`params`:** `lotId` (BIGINT, `paramDirection:"input"`). Route supplies it via query param.
- **`custom`** (each pre-declared with a shaped default — see CLAUDE.md predeclare rule):
  - `lot`: dict with every key the header binds, all `null`/`0`/`""` (`Id,LotName,ItemPartNumber,LotOriginTypeCode,LotStatusCode,LotStatusName,PieceCount,TotalInProcess,InventoryAvailable,CurrentLocationName,ToolId,ToolCode,ToolCavityNumber`).
  - `history`: `[]`, `parents`: `[]`, `children`: `[]`, `pauses`: `[]`.
  - `activeTab`: `"history"`.
- **`scripts.customMethods` → `load()`** (the single data entry point; mirrors the load pattern used in other plant-floor views):

```python
lotId = self.view.params.lotId
if not lotId:
    return
lot = BlueRidge.Lots.Lot.get(lotId)
self.view.custom.lot      = lot or {}
self.view.custom.history  = BlueRidge.Lots.Lot.getHistory(lotId)
self.view.custom.parents  = BlueRidge.Lots.Lot.getParents(lotId)
self.view.custom.children = BlueRidge.Lots.Lot.getChildren(lotId)
self.view.custom.pauses   = BlueRidge.Lots.Lot.getPauses(lotId)
```

- **Invoke `load()`** from `events.system.onStartup` (NOT `events.component` — see `feedback_ignition_onstartup_system_domain`) and from a `propConfig` `onChange` on `params.lotId`. Both bodies: `self.getChild("root").customMethods... ` → simplest is a one-line `self.view.rootContainer.load()` per the verified addressing in `feedback_ignition_view_customMethods_scope`. Script bodies start with a tab (`\t`).

### Components (faithful to mockup)

- **Header:** label `LOT Detail · {view.custom.lot.LotName}`; meta line `{ItemPartNumber} · {LotOriginTypeCode}`; status pill bound to `{view.custom.lot.LotStatusName}`.
- **KPI strip** (flex row of cards): Piece Count, sub `Inventory Available · {InventoryAvailable} · {TotalInProcess} in process`; Current Location `{CurrentLocationName}`; **Tool** card and **Cavity** card each gated by `position.display` bound to expr `!isNull({view.custom.lot.ToolId})` (polymorphic — hidden when NULL). Tool value `{view.custom.lot.ToolCode}`, Cavity `{view.custom.lot.ToolCavityNumber}`.
- **Tab bar** (4 buttons; active style driven by `{view.custom.activeTab}`): each button's `onActionPerformed` sets `self.view.custom.activeTab = "<name>"` (1-line script, starts with `\t`). Use typed style-class slots per `feedback_ignition_tab_container_slots` if using `ia.container.tab`, else 4 buttons + `position.display`-gated panels.
- **Panels** (each gated by `position.display` = `{view.custom.activeTab} = "<name>"`):
  - **History:** `ia.display.flex-repeater`, `props.instances` bound to `view.custom.history`; instance sub-view shows `EventAt` · `EventKind` · `Detail` · `ByUserName`. (Build the row as an inline coord/flex inside the repeater path, or a tiny `_LotDetail/HistoryRow` sub-view.)
  - **Genealogy:** two labelled lists — "Parents" repeater over `view.custom.parents` (`ParentLotName` · `ItemCode` · `RelationshipTypeName`), "Children" repeater over `view.custom.children` (`ChildLotName` · `ItemCode` · `RelationshipTypeName`). Empty-state label when both `len()==0`.
  - **Paused-at:** repeater over `view.custom.pauses` (`LocationName` · `PausedAt` · `PausedReason`). Empty-state label "No open pauses" when `len({view.custom.pauses})==0`.
  - **Linked Container:** static empty-state label only — "Not yet containerized · container links land at Assembly (Phase 6)." No data binding.
- **Action bar:** "← Back to Home" button (`nav` to `/`); **Place Hold** and **Scrap** buttons rendered with `props.enabled:false` and a tooltip "Available in a later phase." No event wiring.

### Steps

- [ ] **Step 1:** Create `LotDetail/view.json` + `resource.json` (scope `G`, `files:["view.json"]`) per the structure above. Root `meta.name:"root"`. Reference `BlueRidge/Views/ShopFloor/InitialsEntry/view.json` for the exact resource.json + chrome style classes.
- [ ] **Step 2:** Add the route to `page-config/config.json`:

```json
    "/shop-floor/lot-detail": {
      "title": "LOT Detail",
      "viewPath": "BlueRidge/Views/ShopFloor/LotDetail"
    }
```

- [ ] **Step 3: Scan**

Run: `pwsh ./scan.ps1` → 200. Confirm no "view.json parse" error in the gateway log.

- [ ] **Step 4: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotDetail" ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json
git commit -m "feat(mpp): polymorphic LOT Detail view (History/Genealogy/Paused-at live; Container/Hold/Scrap stubbed)"
```

---

## Task 6: Designer smoke (manual)

Not a code task — the one step a CLI can't do. After Task 5's scan, in a Perspective session:

- [ ] Navigate to `/shop-floor/lot-detail?lotId=<a die-cast LOT id>` → header shows **Tool + Cavity** cards populated.
- [ ] Navigate with a **Received** LOT id → Tool + Cavity cards are **hidden** (polymorphism via `position.display`).
- [ ] KPI strip shows Piece Count / Inventory Available / in-process / Current Location.
- [ ] **History** tab lists movement/status/attribute rows oldest-first.
- [ ] **Genealogy** tab: a split child LOT shows its parent; a parent shows its children. A gen-0 LOT shows the empty-state.
- [ ] **Paused-at** tab: pause the LOT at a Cell (via existing pause flow / a `LotPause_Place` call) → the row appears; resume → it clears.
- [ ] **Linked Container** shows the static stub; **Place Hold** / **Scrap** are visibly disabled.
- [ ] No Component-Error / Quality-Bad outlines on first paint (confirms pre-declared shaped custom props).

---

## Notes for the implementer

- **No gateway restart anywhere** — `scan.ps1` re-reads NQs, scripts, and views. (Restart is only for custom icon-sprite content.)
- **Commit on `jacques/working`** (not main) per `feedback_jacques_working_branch`; stage explicit paths only (`feedback_git_explicit_staging`).
- **Test teardown FK order** is load-bearing: closure → genealogy → child tables → `Lot` (`feedback_arc2_lot_test_teardown_fk_order`).
- LOT Detail is read-only this push: **no status-row procs, no `editDraft`, no mutations.** Resume-from-Paused-at and label reprint are deferred to the Paused-LOT Indicator view and a later label surface respectively.
```
