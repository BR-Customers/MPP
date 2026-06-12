# Arc 2 Phase 2 — LOT Views (all four) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This is the consolidated handoff plan** for the four deferred Phase 2 LOT Perspective views. It supersedes and subsumes the standalone `2026-06-12-arc2-phase2-lot-detail-view.md` plan (its tasks are reproduced here as Tasks 1, 2, and 6).

**Goal:** Build the four deferred Phase 2 LOT views — **LOT Detail**, **LOT Search**, **Genealogy Viewer**, **Paused-LOT Indicator** — on top of the shipped Phase 2 SQL (migration `0021`), adding two small read procs and one search proc.

**Architecture:** SQL-first. Three SQL tasks (one new proc each + `Lot_Get` extension), each test-driven in the existing `0021_PlantFloor_Lot_Lifecycle` suite. Then one shared Ignition data layer (Core NQs + two entity modules), then the four MPP views/components, then a per-view Designer smoke. Reads everywhere except the single resume mutation.

**Tech Stack:** SQL Server 2022 (`CREATE OR ALTER` repeatable procs, `test.Assert_*`, `Run-Tests.ps1`), Ignition 8.3 file-based Perspective (Core NQs + `BlueRidge.*` scripts; MPP views), `scan.ps1`.

**Specs (source of truth):**
- `docs/superpowers/specs/2026-06-12-arc2-phase2-lot-detail-view-design.md`
- `docs/superpowers/specs/2026-06-12-arc2-phase2-lot-search-view-design.md`
- `docs/superpowers/specs/2026-06-12-arc2-phase2-genealogy-viewer-design.md`
- `docs/superpowers/specs/2026-06-12-arc2-phase2-paused-lot-indicator-design.md`

**Design source of truth (visual):** `mockup/plantFloor.html` — sections `data-route="lot/detail"`, `data-panel="lots"`, `data-panel="genealogy"`, and `.pf-paused-indicator`.

**Read first:** `ignition-context-pack/{03_script_python,04_named_queries,07_conventions_and_antipatterns}.md`; CLAUDE.md (SQL design, FDS-11-011 no-OUTPUT, predeclare-bound-custom-props, status-row-NQ-type-Query, popup-scope-G, onStartup-in-events.system, test-teardown-FK-order). Reference plant-floor views: `BlueRidge/Views/ShopFloor/{HomeRouter,InitialsEntry}`.

**Branch:** commit on `jacques/working`; explicit paths only. **No gateway restart anywhere** — `scan.ps1` re-reads NQs/scripts/views.

---

## Conventions for every SQL task

- Repeatable procs in `sql/migrations/repeatable/R__<schema>_<Proc>.sql`, `CREATE OR ALTER`.
- Tests in `sql/tests/0021_PlantFloor_Lot_Lifecycle/`, `test.BeginTestFile` + `test.Assert_IsEqual` / `test.Assert_RowCount`, INSERT-EXEC into temp tables.
- **Teardown FK order (load-bearing):** `Audit.OperationLog` → `PauseEvent` → `LotGenealogyClosure` → `LotGenealogy` → `LotAttributeChange` → `LotEventLog` → `LotMovement` → `LotStatusHistory` → `Lot`.
- Run one file: `pwsh ./sql/Run-Tests.ps1 -Filter <relativePath>`. Full suite: `pwsh ./sql/Run-Tests.ps1` (baseline 1449/1449).

---

## Task 1: `LotPause_GetByLot` read proc

**Files:** Create `sql/migrations/repeatable/R__Lots_LotPause_GetByLot.sql`; Test `sql/tests/0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql`.

Per-LOT open-pause read for LOT Detail's Paused-at tab. Mirrors `R__Lots_LotPause_GetByLocation.sql` but keyed on `@LotId`, across all Locations, adding `LocationName`.

- [ ] **Step 1: Failing test** — create `070_LotPause_GetByLot.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql';
GO
IF OBJECT_ID(N'tempdb..#GBLFix') IS NOT NULL DROP TABLE #GBLFix;
CREATE TABLE #GBLFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT, @CellB BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;
SELECT TOP 1 @CellB = Id FROM Location.Location WHERE Id <> @CellA AND DeprecatedAt IS NULL ORDER BY Id;
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellA, @PieceCount=30, @AppUserId=1;
INSERT INTO #GBLFix (Tag, Val) SELECT N'Lot', NewId FROM @cr;
INSERT INTO #GBLFix (Tag, Val) VALUES (N'CellA', @CellA), (N'CellB', @CellB);
GO
-- Test 1: paused at two Cells -> two rows oldest-first
DECLARE @Lot BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'Lot');
DECLARE @CellA BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'CellA');
DECLARE @CellB BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'CellB');
DECLARE @p1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p1 EXEC Lots.LotPause_Place @LotId=@Lot, @LocationId=@CellA, @AppUserId=1;
UPDATE Lots.PauseEvent SET PausedAt=DATEADD(SECOND,-30,SYSUTCDATETIME()) WHERE LotId=@Lot AND LocationId=@CellA AND ResumedAt IS NULL;
DECLARE @p2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p2 EXEC Lots.LotPause_Place @LotId=@Lot, @LocationId=@CellB, @AppUserId=1;
CREATE TABLE #gbl (PauseEventId BIGINT, LotId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200), PausedAt DATETIME2(3), PausedByUserId BIGINT, PausedReason NVARCHAR(500));
INSERT INTO #gbl EXEC Lots.LotPause_GetByLot @LotId=@Lot;
DECLARE @n INT=(SELECT COUNT(*) FROM #gbl);
EXEC test.Assert_RowCount @TestName=N'[GetByLot] 2 Cells -> 2 rows', @ExpectedCount=2, @ActualCount=@n;
DECLARE @firstLoc BIGINT=(SELECT TOP 1 LocationId FROM #gbl ORDER BY PausedAt ASC);
EXEC test.Assert_IsEqual @TestName=N'[GetByLot] oldest-first (CellA leads)', @Expected=CAST(@CellA AS NVARCHAR(20)), @Actual=CAST(@firstLoc AS NVARCHAR(20));
DROP TABLE #gbl;
GO
-- Test 2: resume one -> one remains
DECLARE @Lot BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'Lot');
DECLARE @CellA BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'CellA');
DECLARE @paId BIGINT=(SELECT Id FROM Lots.PauseEvent WHERE LotId=@Lot AND LocationId=@CellA AND ResumedAt IS NULL);
DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rr EXEC Lots.LotPause_Resume @PauseEventId=@paId, @AppUserId=1;
CREATE TABLE #gbl2 (PauseEventId BIGINT, LotId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200), PausedAt DATETIME2(3), PausedByUserId BIGINT, PausedReason NVARCHAR(500));
INSERT INTO #gbl2 EXEC Lots.LotPause_GetByLot @LotId=@Lot;
DECLARE @n2 INT=(SELECT COUNT(*) FROM #gbl2);
DROP TABLE #gbl2;
EXEC test.Assert_RowCount @TestName=N'[GetByLot] one remains after resume', @ExpectedCount=1, @ActualCount=@n2;
GO
-- cleanup (FK-safe)
DECLARE @ids TABLE (Id BIGINT); INSERT INTO @ids SELECT Val FROM #GBLFix WHERE Tag=N'Lot';
DELETE ol FROM Audit.OperationLog ol INNER JOIN Lots.PauseEvent pe ON pe.Id=ol.EntityId INNER JOIN @ids x ON x.Id=pe.LotId
    WHERE ol.LogEntityTypeId=(SELECT Id FROM Audit.LogEntityType WHERE Code=N'PauseEvent');
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

- [ ] **Step 2:** Run `-Filter .../070_LotPause_GetByLot.sql` → FAIL ("Could not find stored procedure 'Lots.LotPause_GetByLot'").
- [ ] **Step 3:** Create the proc:

```sql
-- ============================================================
-- Repeatable:  R__Lots_LotPause_GetByLot.sql
-- Description: READ proc for the LOT Detail "Paused-at" tab. OPEN pauses for one
--              LOT across ALL Locations, oldest-first. No status row; empty = none.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LotPause_GetByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pe.Id AS PauseEventId, pe.LotId, pe.LocationId, loc.Name AS LocationName,
           pe.PausedAt, pe.PausedByUserId, pe.PausedReason
    FROM Lots.PauseEvent pe
    INNER JOIN Location.Location loc ON loc.Id = pe.LocationId
    WHERE pe.LotId = @LotId AND pe.ResumedAt IS NULL
    ORDER BY pe.PausedAt ASC, pe.Id ASC;
END;
GO
```

- [ ] **Step 4:** Run the file → PASS (3 assertions); run full suite → green.
- [ ] **Step 5:** Commit:

```bash
git add sql/migrations/repeatable/R__Lots_LotPause_GetByLot.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/070_LotPause_GetByLot.sql
git commit -m "feat(sql): LotPause_GetByLot - per-LOT open-pause read for LOT Detail"
```

---

## Task 2: Extend `Lot_Get` with `ToolCode` + `ToolCavityNumber`

**Files:** Modify `sql/migrations/repeatable/R__Lots_Lot_Get.sql`; Test `sql/tests/0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql`.

LEFT JOINs (NULL for non-die-cast LOTs — the polymorphic header).

- [ ] **Step 1: Failing test** — create `071_LotDetail_LotGet_shape.sql`. The temp table declares the two new columns; INSERT-EXEC fails on column mismatch until the proc returns them.

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql';
GO
DECLARE @OriginRcv BIGINT=(SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT;
SELECT TOP 1 @ItemId=eil.ItemId, @CellA=eil.LocationId FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellA, @PieceCount=30, @AppUserId=1;
DECLARE @Lot BIGINT=(SELECT NewId FROM @cr);
CREATE TABLE #lg (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, Weight DECIMAL(18,4), WeightUomId BIGINT, ToolId BIGINT, ToolCavityId BIGINT,
    VendorLotNumber NVARCHAR(100), MinSerialNumber BIGINT, MaxSerialNumber BIGINT, ParentLotId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT, CreatedByUserId BIGINT, CreatedAtTerminalId BIGINT,
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), UpdatedByUserId BIGINT, RowVersion BIGINT,
    ItemPartNumber NVARCHAR(50), LotOriginTypeCode NVARCHAR(30), LotStatusCode NVARCHAR(30), LotStatusName NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), ToolCode NVARCHAR(50), ToolCavityNumber NVARCHAR(20));
INSERT INTO #lg EXEC Lots.Lot_Get @LotId=@Lot, @LotName=NULL;
DECLARE @n INT=(SELECT COUNT(*) FROM #lg);
EXEC test.Assert_RowCount @TestName=N'[LotGet] extended shape returns the LOT', @ExpectedCount=1, @ActualCount=@n;
DECLARE @toolNull NVARCHAR(10)=(SELECT CASE WHEN ToolCode IS NULL THEN N'1' ELSE N'0' END FROM #lg);
EXEC test.Assert_IsEqual @TestName=N'[LotGet] ToolCode NULL for Received LOT', @Expected=N'1', @Actual=@toolNull;
DROP TABLE #lg;
DECLARE @ids TABLE (Id BIGINT); INSERT INTO @ids VALUES (@Lot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
GO
```

- [ ] **Step 2:** Run → FAIL (INSERT-EXEC column mismatch).
- [ ] **Step 3:** In `R__Lots_Lot_Get.sql`, change the tail of the SELECT/FROM so `CurrentLocationName` gains a trailing comma and two columns + two LEFT JOINs are added:

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

(If `Tools.ToolCavity.CavityNumber` is an INT column, the alias still works and the NVARCHAR(20) test temp column accepts it via implicit convert; keep the alias name `ToolCavityNumber`.)

- [ ] **Step 4:** Run file → PASS; full suite → green. If `0020/050_Lot_Get_List.sql` INSERT-EXECs a fixed-shape temp table, widen it by the two trailing columns and re-run.
- [ ] **Step 5:** Commit:

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Get.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/071_LotDetail_LotGet_shape.sql
git commit -m "feat(sql): Lot_Get resolves ToolCode + ToolCavityNumber (polymorphic header)"
```

---

## Task 3: `Lot_Search` read proc

**Files:** Create `sql/migrations/repeatable/R__Lots_Lot_Search.sql`; Test `sql/tests/0021_PlantFloor_Lot_Lifecycle/072_Lot_Search.sql`.

Free-text search over `LotName` / `VendorLotNumber` / `Item.PartNumber`, optional Status + Origin filters. Mirrors `Lot_List`'s column shape + `LotOriginTypeCode`, `CreatedAt`, `TotalCount`.

- [ ] **Step 1: Failing test** — create `072_Lot_Search.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/072_Lot_Search.sql';
GO
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO
DECLARE @OriginRcv BIGINT=(SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT;
SELECT TOP 1 @ItemId=eil.ItemId, @CellA=eil.LocationId FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellA, @PieceCount=30, @AppUserId=1, @VendorLotNumber=N'VND-SRCH-001';
INSERT INTO #SF (Tag, Val) SELECT N'Lot', NewId FROM @cr;
DECLARE @LotName NVARCHAR(50)=(SELECT MintedLotName FROM @cr);
INSERT INTO #SF (Tag, Val) SELECT N'NameLen', LEN(@LotName);
GO
-- Test 1: search by vendor LOT fragment returns the LOT
CREATE TABLE #r1 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, VendorLotNumber NVARCHAR(100), CurrentLocationId BIGINT, CreatedAt DATETIME2(3),
    ItemPartNumber NVARCHAR(50), LotStatusCode NVARCHAR(30), LotOriginTypeCode NVARCHAR(30),
    CurrentLocationName NVARCHAR(200), TotalCount INT);
INSERT INTO #r1 EXEC Lots.Lot_Search @Query=N'VND-SRCH', @LimitRows=50;
DECLARE @hit INT=(SELECT COUNT(*) FROM #r1 WHERE VendorLotNumber=N'VND-SRCH-001');
DROP TABLE #r1;
EXEC test.Assert_IsEqual @TestName=N'[Search] vendor-LOT fragment matches', @Expected=N'1', @Actual=CAST(@hit AS NVARCHAR(10));
GO
-- Test 2: origin filter excludes non-matching origin
DECLARE @OriginMfg BIGINT=(SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
CREATE TABLE #r2 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, VendorLotNumber NVARCHAR(100), CurrentLocationId BIGINT, CreatedAt DATETIME2(3),
    ItemPartNumber NVARCHAR(50), LotStatusCode NVARCHAR(30), LotOriginTypeCode NVARCHAR(30),
    CurrentLocationName NVARCHAR(200), TotalCount INT);
INSERT INTO #r2 EXEC Lots.Lot_Search @Query=N'VND-SRCH', @LotOriginTypeId=@OriginMfg, @LimitRows=50;
DECLARE @n2 INT=(SELECT COUNT(*) FROM #r2);
DROP TABLE #r2;
EXEC test.Assert_RowCount @TestName=N'[Search] origin filter excludes Received LOT', @ExpectedCount=0, @ActualCount=@n2;
GO
-- cleanup
DECLARE @ids TABLE (Id BIGINT); INSERT INTO @ids SELECT Val FROM #SF WHERE Tag=N'Lot';
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
```

(If `Lot_Create` has no `@VendorLotNumber` param under that exact name, check `R__Lots_Lot_Create.sql` and use the actual param; the proc create earlier confirms a `vendorLotNumber` field exists.)

- [ ] **Step 2:** Run → FAIL ("Could not find stored procedure 'Lots.Lot_Search'").
- [ ] **Step 3:** Create the proc:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_Search.sql
-- Description: READ proc backing LOT Search. Free-text LIKE over LotName /
--              VendorLotNumber / Item.PartNumber + optional Status + Origin
--              filters. One result set; recency-ordered; TOP (@LimitRows).
--              No status row. (Serial/Shipper search deferred -- Phase 3/6 tables.)
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_Search
    @Query           NVARCHAR(100) = NULL,
    @LotStatusId     BIGINT        = NULL,
    @LotOriginTypeId BIGINT        = NULL,
    @LimitRows       INT           = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;
    DECLARE @Q NVARCHAR(120) = CASE WHEN @Query IS NULL OR LTRIM(RTRIM(@Query)) = N''
                                    THEN NULL ELSE N'%' + LTRIM(RTRIM(@Query)) + N'%' END;
    SELECT TOP (@LimitRows)
        l.Id, l.LotName, l.ItemId, l.LotOriginTypeId, l.LotStatusId, l.PieceCount,
        l.VendorLotNumber, l.CurrentLocationId, l.CreatedAt,
        i.PartNumber  AS ItemPartNumber,
        sc.Code       AS LotStatusCode,
        ot.Code       AS LotOriginTypeCode,
        loc.Name      AS CurrentLocationName,
        COUNT(*) OVER() AS TotalCount
    FROM Lots.Lot l
    INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Lots.LotOriginType ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
    WHERE (@Q IS NULL OR l.LotName LIKE @Q OR l.VendorLotNumber LIKE @Q OR i.PartNumber LIKE @Q)
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END;
GO
```

- [ ] **Step 4:** Run file → PASS; full suite → green.
- [ ] **Step 5:** Commit:

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Search.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/072_Lot_Search.sql
git commit -m "feat(sql): Lot_Search - free-text LotName/Vendor/Part search for LOT Search view"
```

---

## Task 4: Core Named Queries (shared layer)

All NQs live in **Core** `ignition/projects/Core/ignition/named-query/lots/`. Clone the existing `lots/Lot_Get/resource.json` shape (`scope:"DG"`, `version:2`, `type:"Query"`, `database:"MPP"`). Single-`@LotId` ones reuse the same one-param resource.json (only `query.sql` differs).

**Create these NQ folders** (`query.sql` + `resource.json` each):

| NQ folder | query.sql | parameters[] (identifier · sqlType) |
|---|---|---|
| `Lot_GetParents` | `EXEC Lots.Lot_GetParents @LotId = :lotId` | `lotId` 3 |
| `Lot_GetChildren` | `EXEC Lots.Lot_GetChildren @LotId = :lotId` | `lotId` 3 |
| `Lot_GetAttributeHistory` | `EXEC Lots.Lot_GetAttributeHistory @LotId = :lotId` | `lotId` 3 |
| `Lot_GetGenealogyTree` | `EXEC Lots.Lot_GetGenealogyTree @LotId = :lotId, @Direction = :direction` | `lotId` 3, `direction` 7 |
| `LotPause_GetByLot` | `EXEC Lots.LotPause_GetByLot @LotId = :lotId` | `lotId` 3 |
| `LotPause_GetByLocation` | `EXEC Lots.LotPause_GetByLocation @LocationId = :locationId` | `locationId` 3 |
| `LotPause_GetCountsByLocation` | `EXEC Lots.LotPause_GetCountsByLocation @LocationId = :locationId` | `locationId` 3 |
| `LotPause_Resume` | `EXEC Lots.LotPause_Resume @PauseEventId = :pauseEventId, @ResumedRemarks = :resumedRemarks, @AppUserId = :appUserId` | `pauseEventId` 3, `resumedRemarks` 7, `appUserId` 3 |
| `Lot_Search` | `EXEC Lots.Lot_Search @Query = :query, @LotStatusId = :lotStatusId, @LotOriginTypeId = :lotOriginTypeId, @LimitRows = :limitRows` | `query` 7, `lotStatusId` 3, `lotOriginTypeId` 3, `limitRows` 2 |
| `LotStatusCode_List` | `EXEC Lots.LotStatusCode_List` (see note) | (none) |
| `LotOriginType_List` | `EXEC Lots.LotOriginType_List` (see note) | (none) |

**resource.json template** (single-`lotId` example; adjust `parameters[]` per the table; `LotPause_Resume` and `Lot_Search` keep `type:"Query"` — status-row/read both use Query):

```json
{
  "scope": "DG", "version": 2, "restricted": false, "overridable": true,
  "files": ["query.sql"],
  "attributes": {
    "useMaxReturnSize": false, "autoBatchEnabled": false, "fallbackValue": "",
    "maxReturnSize": 100, "cacheUnit": "SEC", "type": "Query", "enabled": true,
    "cacheAmount": 1, "cacheEnabled": false, "database": "MPP", "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-06-12T12:00:00Z" },
    "parameters": [{ "type": "Parameter", "identifier": "lotId", "sqlType": 3 }]
  }
}
```

- [ ] **Step 1 — code-table list procs:** Check whether read-only list procs exist for the two code tables (`grep -ril "LotStatusCode" sql/migrations/repeatable`). If absent, create trivial repeatable procs (and `072b`-style shape tests are unnecessary — they're `SELECT Id, Code, Name`):

```sql
-- R__Lots_LotStatusCode_List.sql
CREATE OR ALTER PROCEDURE Lots.LotStatusCode_List AS
BEGIN SET NOCOUNT ON; SELECT Id, Code, Name FROM Lots.LotStatusCode ORDER BY Id; END;
GO
-- R__Lots_LotOriginType_List.sql
CREATE OR ALTER PROCEDURE Lots.LotOriginType_List AS
BEGIN SET NOCOUNT ON; SELECT Id, Code, Name FROM Lots.LotOriginType ORDER BY Id; END;
GO
```

(If list procs already exist under different names, point the NQs at those and skip creating these.)

- [ ] **Step 2:** Author all 11 NQ folders.
- [ ] **Step 3:** `pwsh ./scan.ps1` → 200.
- [ ] **Step 4:** Commit:

```bash
git add ignition/projects/Core/ignition/named-query/lots sql/migrations/repeatable/R__Lots_LotStatusCode_List.sql sql/migrations/repeatable/R__Lots_LotOriginType_List.sql
git commit -m "feat(ignition): Core NQs for all four Phase 2 LOT views (+ code-table list procs)"
```

---

## Task 5: Entity script methods (shared layer)

**Files:** Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`; Create `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotPause/code.py` (+ `resource.json`, `scope:"A"`, `hintScope:2` — clone any sibling module's resource.json).

- [ ] **Step 1 — `Lot` module additions** (append after `assertNotBlocked`):

```python
def getParents(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetParents", {"lotId": lotId})

def getChildren(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetChildren", {"lotId": lotId})

def getHistory(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetAttributeHistory", {"lotId": lotId})

def getPauses(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/LotPause_GetByLot", {"lotId": lotId})

def getGenealogyTree(lotId, direction="Both"):
    BlueRidge.Common.Util.log("lotId=%s direction=%s" % (lotId, direction))
    return BlueRidge.Common.Db.execList("lots/Lot_GetGenealogyTree", {"lotId": lotId, "direction": direction})

def search(query=None, lotStatusId=None, lotOriginTypeId=None, limitRows=100):
    BlueRidge.Common.Util.log("query=%s statusId=%s originId=%s limit=%s" % (query, lotStatusId, lotOriginTypeId, limitRows))
    params = {"query": query, "lotStatusId": lotStatusId, "lotOriginTypeId": lotOriginTypeId, "limitRows": limitRows}
    return BlueRidge.Common.Db.execList("lots/Lot_Search", params)

def getStatusOptions():
    return [{"label": r["Name"], "value": r["Id"]} for r in BlueRidge.Common.Db.execList("lots/LotStatusCode_List")]

def getOriginOptions():
    return [{"label": r["Name"], "value": r["Id"]} for r in BlueRidge.Common.Db.execList("lots/LotOriginType_List")]
```

- [ ] **Step 2 — new `LotPause` module** `code.py`:

```python
"""BlueRidge.Lots.LotPause - thin access to the LOT pause lifecycle reads + resume."""
import BlueRidge.Common.Db
import BlueRidge.Common.Util

def getCountByLocation(locationId):
    """Open-pause count for the indicator badge. Returns dict {LocationId, OpenPauseCount} or None."""
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    return BlueRidge.Common.Db.execOne("lots/LotPause_GetCountsByLocation", {"locationId": locationId})

def getByLocation(locationId):
    """Open pauses at a Cell, oldest-first (indicator detail list). list[dict]."""
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    return BlueRidge.Common.Db.execList("lots/LotPause_GetByLocation", {"locationId": locationId})

def resume(pauseEventId, resumedRemarks=None, appUserId=None):
    """Close an open pause. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("pauseEventId=%s" % pauseEventId)
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"pauseEventId": pauseEventId, "resumedRemarks": resumedRemarks, "appUserId": appUserId}
    return BlueRidge.Common.Db.execMutation("lots/LotPause_Resume", params)
```

- [ ] **Step 3:** `pwsh ./scan.ps1` → 200.
- [ ] **Step 4 — Script Console smoke (Core scope)** with a real lotId / locationId from `MPP_MES_Dev`: each `Lot.getHistory/getParents/getChildren/getPauses/getGenealogyTree/search` returns a list; `LotPause.getCountByLocation/getByLocation` return without error.
- [ ] **Step 5:** Commit:

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotPause
git commit -m "feat(ignition): Lot read methods + LotPause entity module for Phase 2 views"
```

---

## Task 6: LOT Detail view + route

**Files:** Create `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/LotDetail/{view.json,resource.json}`; Modify `page-config/config.json`.

Faithful to `mockup/plantFloor.html` `section[data-route="lot/detail"]`. Read-only — no `editDraft`, no mutations.

- **`params`:** `lotId` (input).
- **`custom`** (each pre-declared, shaped default): `lot` (dict with `Id,LotName,ItemPartNumber,LotOriginTypeCode,LotStatusCode,LotStatusName,PieceCount,TotalInProcess,InventoryAvailable,CurrentLocationName,ToolId,ToolCode,ToolCavityNumber` all null/0/""); `history`/`parents`/`children`/`pauses` = `[]`; `activeTab` = `"history"`.
- **`load()` customMethod:**

```python
lotId = self.view.params.lotId
if not lotId:
    return
self.view.custom.lot      = BlueRidge.Lots.Lot.get(lotId) or {}
self.view.custom.history  = BlueRidge.Lots.Lot.getHistory(lotId)
self.view.custom.parents  = BlueRidge.Lots.Lot.getParents(lotId)
self.view.custom.children = BlueRidge.Lots.Lot.getChildren(lotId)
self.view.custom.pauses   = BlueRidge.Lots.Lot.getPauses(lotId)
```

Invoke from `events.system.onStartup` and a `params.lotId` `onChange` (both one-liner `self.view.rootContainer.load()`; bodies start with `\t`).

- **Components (faithful to mockup):** header (`LOT Detail · {lot.LotName}`, meta `{lot.ItemPartNumber} · {lot.LotOriginTypeCode}`, status pill `{lot.LotStatusName}`); KPI strip (Piece Count + `Inventory Available · {lot.InventoryAvailable} · {lot.TotalInProcess} in process`, Current Location, **Tool**/**Cavity** cards each `position.display` ← `!isNull({view.custom.lot.ToolId})`); 4-button tab bar driven by `{view.custom.activeTab}`; four `position.display`-gated panels — **History** repeater over `view.custom.history` (`EventAt·EventKind·Detail·ByUserName`), **Genealogy** Parents repeater (`view.custom.parents`: `ParentLotName·ItemCode·RelationshipTypeName`) + Children repeater (`view.custom.children`: `ChildLotName·ItemCode·RelationshipTypeName`), **Paused-at** repeater over `view.custom.pauses` (`LocationName·PausedAt·PausedReason`, empty-state when `len()==0`), **Linked Container** static stub label; action bar: Back (`nav /`) + **Place Hold**/**Scrap** rendered `props.enabled:false` with "later phase" tooltip.
- Lists via `ia.display.flex-repeater` (or `ia.display.table` with the full ~25-key column schema). Pre-declare all bound props.

- [ ] **Step 1:** Create the view + resource.json (scope `G`). Reference `InitialsEntry/view.json` for resource.json + chrome style classes.
- [ ] **Step 2:** Add route to `page-config/config.json`:

```json
    "/shop-floor/lot-detail": { "title": "LOT Detail", "viewPath": "BlueRidge/Views/ShopFloor/LotDetail" }
```

- [ ] **Step 3:** `pwsh ./scan.ps1` → 200; no view.json parse error in gateway log.
- [ ] **Step 4:** Commit:

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotDetail" ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json
git commit -m "feat(mpp): polymorphic LOT Detail view (History/Genealogy/Paused-at live; Container/Hold/Scrap stubbed)"
```

---

## Task 7: LOT Search view + route

**Files:** Create `BlueRidge/Views/ShopFloor/LotSearch/{view.json,resource.json}`; Modify `page-config/config.json`.

Faithful to `div[data-panel="lots"]`. Read-only.

- **`custom`:** `query` (""), `statusId` (null), `originId` (null), `results` (`[]`), `statusOptions` (`[]`), `originOptions` (`[]`).
- **`load()` (onStartup):** `self.view.custom.statusOptions = BlueRidge.Lots.Lot.getStatusOptions()`; `...originOptions = BlueRidge.Lots.Lot.getOriginOptions()`.
- **`search()` customMethod:**

```python
self.view.custom.results = BlueRidge.Lots.Lot.search(
    self.view.custom.query or None,
    self.view.custom.statusId,
    self.view.custom.originId,
    100)
```

- **Components:** search bar — Query text-field bidi → `view.custom.query` (commit on `dom.onBlur` → `self.view.rootContainer.search()`), Status dropdown (`props.options` ← `view.custom.statusOptions`, value bidi → `statusId`), Origin dropdown (← `originOptions`, → `originId`), Search button (`onActionPerformed` → `search()`). Results header `len(results) + " results"`; results via `ia.display.table` (full column schema: Origin `LotOriginTypeCode`, LotName, detail `ItemPartNumber · PieceCount · CurrentLocationName`, status `LotStatusCode`, `CreatedAt`) or a flex-repeater; **row click → nav `/shop-floor/lot-detail?lotId={row.Id}`** (table `onSelectionChange` reads `selection.data[0].Id`; see `feedback_ignition_table_onselectionchange`). Placeholder text: "LotName · Vendor LOT · Part Number".
- Pre-declare all bound props. **Gate behind the elevated role** (per spec §6) — confirm the exact security level against `HomeRouter`'s auth pattern.

- [ ] **Step 1:** Create view + resource.json.
- [ ] **Step 2:** Route: `"/shop-floor/lot-search": { "title": "LOT Search", "viewPath": "BlueRidge/Views/ShopFloor/LotSearch" }`.
- [ ] **Step 3:** `pwsh ./scan.ps1` → 200.
- [ ] **Step 4:** Commit `feat(mpp): LOT Search view (LotName/Vendor/Part text search -> LOT Detail)`.

---

## Task 8: Genealogy Viewer view + route

**Files:** Create `BlueRidge/Views/ShopFloor/GenealogyViewer/{view.json,resource.json}`; Modify `page-config/config.json`.

Faithful to `div[data-panel="genealogy"]`. Read-only. Depth-indented flat repeater (NOT `ia.display.tree`).

- **`custom`:** `query` (""), `direction` ("Both"), `rootLot` (shaped-empty dict), `nodes` (`[]`), `ancestors` (`[]`), `descendants` (`[]`).
- **`walk()` customMethod:**

```python
q = self.view.custom.query
if not q:
    return
root = BlueRidge.Lots.Lot.get(lotName=q)
if not root:
    BlueRidge.Common.Notify.toast("No LOT found", "No LOT named %s" % q, "warning")
    return
nodes = BlueRidge.Lots.Lot.getGenealogyTree(root["Id"], self.view.custom.direction)
self.view.custom.rootLot     = root
self.view.custom.nodes       = nodes
self.view.custom.ancestors   = [n for n in nodes if n.get("Direction") == "Ancestor"]
self.view.custom.descendants = [n for n in nodes if n.get("Direction") == "Descendant"]
```

(Filter in the method, not an expression — Ignition expressions can't iterate, `feedback_ignition_no_foreach_in_expressions`.) Wire to "Walk Tree" button + Query `dom.onBlur`.

- **Components:** search bar — Query text-field bidi → `query`; Direction dropdown options `[{label:"Both...",value:"Both"},{label:"Ancestors only",value:"Ancestors"},{label:"Descendants only",value:"Descendants"}]` bidi → `direction`; Walk button → `walk()`. Header `Tree for {rootLot.LotName} · {len(nodes)} nodes`. **Ancestors** section (repeater over `view.custom.ancestors`) + root row (`rootLot`) + **Descendants** section (repeater over `view.custom.descendants`); each node row indents by `Depth` (bind a left-margin/padding style to `{instance.Depth} * 18` px via a script transform), shows `{LotName} · {ItemCode} · depth {Depth}`, click → nav `/shop-floor/lot-detail?lotId={LotId}`. Empty-state label when `len(nodes)==0`.
- Pre-declare all bound props. Gate elevated.

- [ ] **Step 1:** Create view + resource.json.
- [ ] **Step 2:** Route: `"/shop-floor/genealogy": { "title": "Genealogy", "viewPath": "BlueRidge/Views/ShopFloor/GenealogyViewer" }`.
- [ ] **Step 3:** `pwsh ./scan.ps1` → 200.
- [ ] **Step 4:** Commit `feat(mpp): Genealogy Viewer (closure-walk depth-indented tree -> LOT Detail)`.

---

## Task 9: Paused-LOT Indicator component + popup + demo

**Files:** Create `BlueRidge/Components/PlantFloor/PausedLotIndicator/{view.json,resource.json}`, `BlueRidge/Components/Popups/PausedLotList/{view.json,resource.json}`, `BlueRidge/Views/ShopFloor/PausedDemo/{view.json,resource.json}`; Modify `page-config/config.json`.

- **`PausedLotIndicator`** (embeddable badge): param `locationId` (input). `custom.count` default `{"OpenPauseCount":0}`; `load()` (onStartup + `locationId` onChange): `self.view.custom.count = BlueRidge.Lots.LotPause.getCountByLocation(self.view.params.locationId) or {"OpenPauseCount":0}`. Renders `⏸ Paused {count.OpenPauseCount}` (amber pill, `.pf-paused-indicator` styling). `dom.onClick` (scope `"G"`) → `openPopup` id `mpp-paused-list`, view `BlueRidge/Components/Popups/PausedLotList`, modal, params `{"locationId": self.view.params.locationId}`.
- **`PausedLotList`** (popup): param `locationId`. `custom.pauses` (`[]`); `load()`: `self.view.custom.pauses = BlueRidge.Lots.LotPause.getByLocation(self.view.params.locationId)`. Repeater rows (`LotName·ItemCode·PausedAt·PausedByUserId`) each with a **Resume** button whose `onActionPerformed` (scope `"G"`) →

```python
result = BlueRidge.Lots.LotPause.resume(event.source.custom.pauseEventId)
BlueRidge.Common.Ui.notifyResult(result, successTitle="Resumed")
if result.get("Status"):
    self.view.custom.pauses = BlueRidge.Lots.LotPause.getByLocation(self.view.params.locationId)
    system.perspective.sendMessage("pausedLotResumed", {"lotId": event.source.custom.lotId}, scope="page")
```

(Each repeater instance carries `pauseEventId`/`lotId` from the row dict. Resume NQ is `type:"Query"` — status-row mutation.) Close button + empty-state when `len(pauses)==0`.
- **`PausedDemo`** page (`/shop-floor/paused-demo`): a Cell dropdown (options from `Location.Location_ListByTier` Cell tier, or a hardcoded known Cell for the smoke) feeding `locationId` into an embedded `PausedLotIndicator`, so the badge+popup+resume loop is smoke-testable before any work screen exists.

- [ ] **Step 1:** Create the two components + the demo page (+ resource.json each).
- [ ] **Step 2:** Route: `"/shop-floor/paused-demo": { "title": "Paused Demo", "viewPath": "BlueRidge/Views/ShopFloor/PausedDemo" }`.
- [ ] **Step 3:** `pwsh ./scan.ps1` → 200.
- [ ] **Step 4:** Commit `feat(mpp): Paused-LOT Indicator component + list popup + resume + demo page`.

---

## Task 10: Designer smoke (manual — all four)

After Task 9's scan, in a Perspective session (no gateway restart):

- [ ] **LOT Detail** `/shop-floor/lot-detail?lotId=<die-cast id>` → Tool/Cavity cards show; `<received id>` → hidden. History lists movement/status/attribute oldest-first. Genealogy shows parents/children (split LOT) or empty-state (gen-0). Paused-at: pause the LOT → row appears, resume → clears. Container stub + disabled Hold/Scrap. No Component-Error on first paint.
- [ ] **LOT Search** `/shop-floor/lot-search` → LotName / Vendor / Part fragment + Search lists matches; Status + Origin dropdowns filter; row click opens LOT Detail.
- [ ] **Genealogy Viewer** `/shop-floor/genealogy` → LotName + Direction + Walk renders ancestors-above / descendants-below indented; node click → LOT Detail; gen-0 → empty-state.
- [ ] **Paused-LOT Indicator** `/shop-floor/paused-demo` → pause two LOTs at the chosen Cell → badge "2"; open popup → both oldest-first; Resume one → toast, list→1, badge→1; resume as a different operator records the resumer.

---

## Notes for the implementer

- **No gateway restart anywhere** — `scan.ps1` suffices for NQs/scripts/views.
- **Branch `jacques/working`; explicit `git add` paths only.**
- **Test teardown FK order** (closure → genealogy → child tables → `Lot`) is load-bearing.
- All views read-only except `LotPause.resume` (the one mutation; routes through `notifyResult`, NQ `type:"Query"`).
- Deferred-by-design (do NOT build): SerialNumber/Shipper search, per-edge genealogy relationship labels, resume active-context handoff, Linked-Container/Hold/Scrap wiring. These are later-phase and called out in each spec.
- Suggested execution order is the task order (SQL 1-3 → shared 4-5 → views 6-9 → smoke 10). Tasks 6-9 are independent of each other once 4-5 land and may be parallelized.
```
