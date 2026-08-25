# LOT Search Advanced + Trace Detail Panels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver FDS-12-002, FDS-12-003 and FDS-12-004 — a new `Lots.Lot_SearchAdvanced` proc behind the extended LOT Search screen with row-click drill-through, and serial + container detail panels on the existing Global Trace surface.

**Architecture:** Five new read procs, five new named queries in the **Core** project, new functions appended to four existing entity-script modules, and two existing Perspective views extended in Designer. `Lots.Lot_Search` is **frozen** — it has three live consumers. **No schema migration.**

**Tech Stack:** SQL Server 2022, Ignition 8.3 Perspective (file-based), Jython 2.7, `sqlcmd`-driven test harness.

**Spec:** `docs/superpowers/specs/2026-08-24-lot-search-and-trace-detail-panels-design.md`

## Global Constraints

- **`Lots.Lot_Search` and `lots/Lot_Search` are FROZEN.** Do not change the proc, its named query, `BlueRidge.Lots.Lot.search()`, or `sql/tests/0021_PlantFloor_Lot_Lifecycle/077_Lot_Search.sql`. Three consumers depend on them, one of which (`HoldManagement`) calls `search()` **positionally**.
- **No `OUTPUT` parameters** (FDS-11-011). One result set per proc. Empty result set = not found; no invented 404.
- **Three-layer rule:** View → Entity script → `Common.Db` → `system.db`. A view **never** calls `system.db.*`.
- **Inline event scripts cap at 1–3 lines.** Anything longer is a one-liner delegating to an entity script.
- Naming: `UpperCamelCase`; `BIGINT` ids; `NVARCHAR` never `VARCHAR`; `DATETIME2(3)` never `DATETIME`.
- **Timestamps stored UTC, displayed Eastern** — convert at every operator-facing read with `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- Schema-qualify every DB reference. `EXEC` parameters must be literals or `@variables`.
- **All named queries live in `Core`.** `resource.json` must be `version: 2` — Designer 8.3.5 NPEs on `version: 1`.
- **`sqlType` is Designer's own enum, not `java.sql.Types`:** `3` = BIGINT, `7` = String, `8` = DateTime, `2` = Int4, `6` = Boolean. Never `-5` / `-9`.
- **Tests run against a private throwaway database.** `cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "<yours>"`. **Never** bare `MPP_MES_Test` (concurrent work drops it) and **never** `MPP_MES_Dev`. Grep output for **BOTH** `FAIL` and `ERROR running` — a sqlcmd error surfaces as runner exit-1 with green assertion counts.
- Existing views are edited in **Designer**, never by file edit. New named queries and Python are file-edited, then `.\scan.ps1`.
- Commit to `jacques/working`. Stage explicit paths — never `git add -u` / `-A`. No `Co-Authored-By` trailer.

---

## File Structure

| File | Responsibility |
|---|---|
| `sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql` | **New.** 12-parameter filtered LOT browse (FDS-12-004). |
| `sql/migrations/repeatable/R__Lots_SerializedPart_GetTraceDetail.sql` | **New.** One-row serial trace payload (FDS-12-002). |
| `sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql` | **New.** One-row container trace payload (FDS-12-003). |
| `sql/migrations/repeatable/R__Lots_Container_ListSerials.sql` | **New.** Sibling — the container's serial list. |
| `sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql` | **New.** Sibling — full hold history. `Hold_GetOpenByContainer` filters to open only and cannot serve FDS-12-003. |
| `sql/tests/0067_Lot_SearchAdvanced/010_filters.sql` | Per-filter coverage. |
| `sql/tests/0067_Lot_SearchAdvanced/020_date_boundary.sql` | Eastern-day conversion. |
| `sql/tests/0067_Lot_SearchAdvanced/030_origin_conditional.sql` | NULL-Tool LOTs excluded by Die filter. |
| `sql/tests/0067_Lot_SearchAdvanced/040_total_count.sql` | `TotalCount` across a pager boundary. |
| `sql/tests/0067_Lot_SearchAdvanced/050_signature_parity.sql` | Proc parameter list == the 12 canonical names; `Lot_Search` still frozen at 4. |
| `sql/tests/0068_Trace_Detail_Reads/010_serial_detail.sql` | Serial payload. |
| `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql` | Container payload + both siblings. |
| `.../Core/ignition/named-query/lots/Lot_SearchAdvanced/` | **New.** 12 params. |
| `.../Core/ignition/named-query/lots/SerializedPart_GetTraceDetail/` | **New.** |
| `.../Core/ignition/named-query/lots/Container_GetTraceDetail/` | **New.** |
| `.../Core/ignition/named-query/lots/Container_ListSerials/` | **New.** |
| `.../Core/ignition/named-query/quality/Hold_ListByContainer/` | **New.** Under `quality/`, matching its schema. |
| `.../Core/.../script-python/BlueRidge/Lots/Lot/code.py` | **Append.** `_EMPTY_FILTERS`, `emptyFilters`, `searchAdvanced`, `exportCsv`. `search()` untouched. |
| `.../Core/.../script-python/BlueRidge/Lots/SerializedPart/code.py` | **Append.** `getTraceDetail`, `getTraceDetailOrEmpty`. |
| `.../Core/.../script-python/BlueRidge/Lots/Container/code.py` | **Append.** `getTraceDetail`, `getTraceDetailOrEmpty`, `listSerials`, `listHolds`. |
| `.../Core/.../script-python/BlueRidge/Lots/GlobalTrace/code.py` | **Append.** `loadDetail` dispatcher. |
| `.../MPP/.../views/BlueRidge/Views/ShopFloor/LotSearch/view.json` | 8 filters, 3 columns + hidden `Id` column, row-click, CSV, pickle cleanup. **Designer.** |
| `.../MPP/.../views/BlueRidge/Views/ShopFloor/GlobalTrace/view.json` | Serial + container panels. **Designer.** |

Tasks 1–4 SQL, Task 5 named queries, Task 6 entity scripts, Tasks 7–8 the Designer view edits (independent of each other).

---

## Task 1: `Lots.Lot_SearchAdvanced`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql`
- Test: `sql/tests/0067_Lot_SearchAdvanced/010_filters.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Lots.Lot_SearchAdvanced` with 12 parameters — `@Query NVARCHAR(100)`, `@ItemId BIGINT`, `@CreatedFromEt DATE`, `@CreatedToEt DATE`, `@ToolId BIGINT`, `@ToolCavityId BIGINT`, `@LocationId BIGINT`, `@MachineLocationId BIGINT`, `@ShiftId BIGINT`, `@LotStatusId BIGINT`, `@LotOriginTypeId BIGINT`, `@LimitRows INT = 100` — all others defaulting `NULL`. Result columns: `Id, LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, VendorLotNumber, CurrentLocationId, CreatedAt, ItemPartNumber, LotStatusCode, LotOriginTypeCode, CurrentLocationName, LastOperationName, ToolCode, CavityNumber, OriginMachineName, TotalCount`.

**Context:** `Lots.Lot` carries FK-backed `ToolId` / `ToolCavityId` **and** legacy `DieNumber` / `CavityNumber` `NVARCHAR` columns that are no longer maintained — use the FK pair. Origin machine is `Workorder.DieCastContribution.CellLocationId` (write-time press stamp, migration `0061`), never derived from `LotMovement`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0067_Lot_SearchAdvanced/010_filters.sql`:

```sql
-- =============================================
-- File:         0067_Lot_SearchAdvanced/010_filters.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-004 filter coverage for Lots.Lot_SearchAdvanced.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/010_filters.sql';
GO

CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityNumber INT, OriginMachineName NVARCHAR(200),
    TotalCount INT
);

DECLARE @n INT, @AnyItemId BIGINT, @AnyLocId BIGINT;
SELECT TOP (1) @AnyItemId = ItemId, @AnyLocId = CurrentLocationId FROM Lots.Lot ORDER BY Id;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsTrue @TestName = N'[SearchAdv] unfiltered returns at least one row', @Condition = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @ItemId = @AnyItemId;
SELECT @n = COUNT(*) FROM #LS WHERE ItemId <> @AnyItemId;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @ItemId returns no foreign items',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- Location filter ALWAYS walks descendants: a LOT sitting exactly at @AnyLocId
-- must be inside the returned set.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @LocationId = @AnyLocId;
SELECT @n = COUNT(*) FROM #LS WHERE CurrentLocationId = @AnyLocId;
EXEC test.Assert_IsTrue @TestName = N'[SearchAdv] location filter includes LOTs at that exact location',
    @Condition = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @LimitRows = 1;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @LimitRows = 1 returns exactly one row',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'ZZZ-NO-SUCH-LOT-ZZZ';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] unmatched query returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @ItemId = @AnyItemId, @LocationId = @AnyLocId, @LimitRows = 50;
SELECT @n = COUNT(*) FROM #LS WHERE ItemId <> @AnyItemId;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] combined filters respect @ItemId',
    @Expected = N'0', @Actual = @n;

DROP TABLE #LS;
GO
```

- [ ] **Step 2: Run and verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0067"
```

Expected: FAIL — `Could not find stored procedure 'Lots.Lot_SearchAdvanced'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql`:

```sql
-- =============================================
-- Repeatable:  R__Lots_Lot_SearchAdvanced.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-004 LOT Search. Filtered browse: free text, item, Eastern
--              created-day range, die, cavity, location (always incl.
--              descendants), origin machine, shift, status, origin type.
--              One result set (FDS-11-011); recency-ordered; TOP (@LimitRows)
--              with COUNT(*) OVER() AS TotalCount for the pager.
--
--              SEPARATE from Lots.Lot_Search, which is FROZEN: it has three
--              consumers (test 077, BlueRidge.Lots.Lot.search, and the
--              HoldManagement bulk picker, which calls search() POSITIONALLY).
--              Widening it would break all three. See design spec section 2.3.
--
--              Die / Cavity / Machine / Shift are die-cast-origin dimensions.
--              Lot.ToolId / ToolCavityId are NULL on merged LOTs (OI-05) and on
--              non-cast origins, and machine resolves through
--              Workorder.DieCastContribution -- so any of those four narrows to
--              die-cast-origin LOTs. Intended; surfaced in the UI, not
--              compensated for here.
--
--              Origin machine is DieCastContribution.CellLocationId (the press,
--              stamped at write time by migration 0061). Deliberately NOT
--              derived from LotMovement: 0061 exists to stop live re-derivation
--              of the press, and a movement-based derivation reintroduces the
--              same drift.
--
--              Dates are Eastern calendar days, inclusive both ends, converted
--              to a half-open UTC range here so the filter agrees with the
--              Eastern-converted CreatedAt in the SELECT. (Audit.ConfigLog_List
--              does NOT do this -- it displays Eastern but filters raw UTC, so
--              near midnight its filter and column disagree. Do not copy it.)
--
--              The legacy Lot.DieNumber / Lot.CavityNumber columns are used
--              NOWHERE here -- superseded by ToolId / ToolCavityId.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Lot_SearchAdvanced
    @Query             NVARCHAR(100) = NULL,
    @ItemId            BIGINT        = NULL,
    @CreatedFromEt     DATE          = NULL,
    @CreatedToEt       DATE          = NULL,
    @ToolId            BIGINT        = NULL,
    @ToolCavityId      BIGINT        = NULL,
    @LocationId        BIGINT        = NULL,
    @MachineLocationId BIGINT        = NULL,
    @ShiftId           BIGINT        = NULL,
    @LotStatusId       BIGINT        = NULL,
    @LotOriginTypeId   BIGINT        = NULL,
    @LimitRows         INT           = 100
AS
BEGIN
    SET NOCOUNT ON;

    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;

    DECLARE @Q NVARCHAR(120) = CASE
        WHEN @Query IS NULL OR LTRIM(RTRIM(@Query)) = N'' THEN NULL
        ELSE N'%' + LTRIM(RTRIM(@Query)) + N'%' END;

    DECLARE @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL;
    IF @CreatedFromEt IS NOT NULL
        SET @FromUtc = CAST(CAST(@CreatedFromEt AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @CreatedToEt IS NOT NULL
        SET @ToUtc = CAST(CAST(DATEADD(DAY, 1, @CreatedToEt) AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    ;WITH Descendants AS (
        SELECT Id FROM Location.Location WHERE Id = @LocationId
        UNION ALL
        SELECT c.Id FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    SELECT TOP (@LimitRows)
        l.Id, l.LotName, l.ItemId, l.LotOriginTypeId, l.LotStatusId, l.PieceCount,
        l.VendorLotNumber, l.CurrentLocationId,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        i.PartNumber         AS ItemPartNumber,
        sc.Code              AS LotStatusCode,
        ot.Code              AS LotOriginTypeCode,
        loc.Name             AS CurrentLocationName,
        lastop.OperationName AS LastOperationName,
        t.Code               AS ToolCode,
        tc.CavityNumber      AS CavityNumber,
        press.MachineName    AS OriginMachineName,
        COUNT(*) OVER()      AS TotalCount
    FROM Lots.Lot l
    INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Lots.LotOriginType ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
    LEFT  JOIN Tools.Tool         t   ON t.Id   = l.ToolId
    LEFT  JOIN Tools.ToolCavity   tc  ON tc.Id  = l.ToolCavityId
    OUTER APPLY (
        SELECT TOP (1) oty.Name AS OperationName
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot2.OperationTypeId
        WHERE pe.LotId = l.Id
        ORDER BY pe.EventAt DESC, pe.Id DESC
    ) lastop
    OUTER APPLY (
        SELECT TOP (1) cell.Name AS MachineName
        FROM Workorder.DieCastContribution dcc
        INNER JOIN Location.Location cell ON cell.Id = dcc.CellLocationId
        WHERE dcc.LotId = l.Id AND dcc.CellLocationId IS NOT NULL
        ORDER BY dcc.EventAt ASC, dcc.Id ASC
    ) press
    WHERE (@Q IS NULL OR l.LotName LIKE @Q OR l.VendorLotNumber LIKE @Q OR i.PartNumber LIKE @Q)
      AND (@ItemId          IS NULL OR l.ItemId          = @ItemId)
      AND (@FromUtc         IS NULL OR l.CreatedAt      >= @FromUtc)
      AND (@ToUtc           IS NULL OR l.CreatedAt       < @ToUtc)
      AND (@ToolId          IS NULL OR l.ToolId          = @ToolId)
      AND (@ToolCavityId    IS NULL OR l.ToolCavityId    = @ToolCavityId)
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
      AND (@LocationId      IS NULL OR l.CurrentLocationId IN (SELECT Id FROM Descendants))
      AND (@MachineLocationId IS NULL OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution dm
              WHERE dm.LotId = l.Id AND dm.CellLocationId = @MachineLocationId))
      AND (@ShiftId IS NULL OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution ds
              WHERE ds.LotId = l.Id AND ds.ShiftId = @ShiftId))
    ORDER BY l.CreatedAt DESC, l.Id DESC
    OPTION (MAXRECURSION 100);
END
GO
```

- [ ] **Step 4: Run and verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0067"
```

Expected: PASS, 6 assertions. Grep the output for both `FAIL` and `ERROR running`.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql sql/tests/0067_Lot_SearchAdvanced/010_filters.sql
git commit -m "feat(sql): Lot_SearchAdvanced with the FDS-12-004 filter set"
```

---

## Task 2: Boundary, origin and signature-parity tests

**Files:**
- Test: `sql/tests/0067_Lot_SearchAdvanced/020_date_boundary.sql`
- Test: `sql/tests/0067_Lot_SearchAdvanced/030_origin_conditional.sql`
- Test: `sql/tests/0067_Lot_SearchAdvanced/040_total_count.sql`
- Test: `sql/tests/0067_Lot_SearchAdvanced/050_signature_parity.sql`

**Interfaces:**
- Consumes: `Lots.Lot_SearchAdvanced` from Task 1 (signature and result shape as declared there).
- Produces: nothing consumed later.

The four behaviours most likely to regress silently.

- [ ] **Step 1: Write the date-boundary test**

Create `sql/tests/0067_Lot_SearchAdvanced/020_date_boundary.sql`:

```sql
-- =============================================
-- File:         0067_Lot_SearchAdvanced/020_date_boundary.sql
-- Author:       Blue Ridge Automation
-- Description:  The Eastern-day filter must agree with the Eastern-converted
--               CreatedAt column. A LOT created 01:00 UTC on day D belongs to
--               Eastern day D-1 (20:00 EST), so it must be found by
--               @CreatedToEt = D-1 and NOT by @CreatedFromEt = D.
--               January date chosen deliberately -- EST, no DST ambiguity.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/020_date_boundary.sql';
GO

CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityNumber INT, OriginMachineName NVARCHAR(200),
    TotalCount INT
);

DECLARE @n INT, @LotId BIGINT;
DECLARE @LotName NVARCHAR(50) = N'TEST-TZ-BOUNDARY-01';
DECLARE @ItemId BIGINT, @LocId BIGINT, @StatusId BIGINT, @OriginId BIGINT, @UserId BIGINT;

SELECT TOP (1) @ItemId = ItemId, @LocId = CurrentLocationId, @StatusId = LotStatusId,
               @OriginId = LotOriginTypeId, @UserId = CreatedByUserId
FROM Lots.Lot ORDER BY Id;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (@LotName, @ItemId, @OriginId, @StatusId, 1, @LocId, @UserId,
        CAST(N'2026-01-15T01:00:00' AS DATETIME2(3)));
SET @LotId = SCOPE_IDENTITY();

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = @LotName,
    @CreatedFromEt = '2026-01-14', @CreatedToEt = '2026-01-14';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] 01:00 UTC LOT found on the prior Eastern day',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = @LotName,
    @CreatedFromEt = '2026-01-15', @CreatedToEt = '2026-01-15';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] 01:00 UTC LOT absent from the UTC day',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = @LotName,
    @CreatedFromEt = '2026-01-13', @CreatedToEt = '2026-01-14';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @CreatedToEt is inclusive of its whole day',
    @Expected = N'1', @Actual = @n;

DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @LotId OR AncestorLotId = @LotId;
DELETE FROM Lots.Lot WHERE Id = @LotId;
DROP TABLE #LS;
GO
```

> **Teardown order matters.** `Lot_Create` writes a self-row into `Lots.LotGenealogyClosure`; deleting the LOT first raises `Msg 547`. This test inserts directly so the closure row may not exist — the DELETE is harmless either way and keeps the pattern correct.

- [ ] **Step 2: Write the origin-conditional test**

Create `sql/tests/0067_Lot_SearchAdvanced/030_origin_conditional.sql`:

```sql
-- =============================================
-- File:         0067_Lot_SearchAdvanced/030_origin_conditional.sql
-- Author:       Blue Ridge Automation
-- Description:  Die / Cavity are die-cast-origin dimensions. A LOT with NULL
--               ToolId (merged LOT per OI-05, or a non-cast origin) appears in
--               an unfiltered search and disappears under any @ToolId.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/030_origin_conditional.sql';
GO

CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityNumber INT, OriginMachineName NVARCHAR(200),
    TotalCount INT
);

DECLARE @n INT, @LotId BIGINT, @AnyToolId BIGINT;
DECLARE @LotName NVARCHAR(50) = N'TEST-NULLTOOL-01';
DECLARE @ItemId BIGINT, @LocId BIGINT, @StatusId BIGINT, @OriginId BIGINT, @UserId BIGINT;

SELECT TOP (1) @ItemId = ItemId, @LocId = CurrentLocationId, @StatusId = LotStatusId,
               @OriginId = LotOriginTypeId, @UserId = CreatedByUserId
FROM Lots.Lot ORDER BY Id;
SELECT TOP (1) @AnyToolId = Id FROM Tools.Tool ORDER BY Id;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, ToolId, ToolCavityId)
VALUES (@LotName, @ItemId, @OriginId, @StatusId, 1, @LocId, @UserId, NULL, NULL);
SET @LotId = SCOPE_IDENTITY();

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = @LotName;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] NULL-Tool LOT returned unfiltered',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #LS WHERE ToolCode IS NOT NULL OR CavityNumber IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] NULL-Tool LOT yields NULL ToolCode and CavityNumber',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = @LotName, @ToolId = @AnyToolId;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] NULL-Tool LOT excluded by any @ToolId',
    @Expected = N'0', @Actual = @n;

DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @LotId OR AncestorLotId = @LotId;
DELETE FROM Lots.Lot WHERE Id = @LotId;
DROP TABLE #LS;
GO
```

- [ ] **Step 3: Write the TotalCount test**

Create `sql/tests/0067_Lot_SearchAdvanced/040_total_count.sql`:

```sql
-- =============================================
-- File:         0067_Lot_SearchAdvanced/040_total_count.sql
-- Author:       Blue Ridge Automation
-- Description:  COUNT(*) OVER() must report the FULL match count, not the
--               TOP-limited page size -- the pager depends on it.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/040_total_count.sql';
GO

CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityNumber INT, OriginMachineName NVARCHAR(200),
    TotalCount INT
);

DECLARE @Rows INT, @Total INT, @AllRows INT, @n INT;

INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @LimitRows = 1000;
SELECT @AllRows = COUNT(*) FROM #LS;
DELETE FROM #LS;

IF @AllRows < 2
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] TotalCount test skipped -- fewer than 2 LOTs seeded',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @LimitRows = 1;
    SELECT @Rows = COUNT(*), @Total = MAX(TotalCount) FROM #LS;
    DELETE FROM #LS;

    EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] page returns exactly one row',
        @Expected = N'1', @Actual = @Rows;

    SET @n = CASE WHEN @Total = @AllRows THEN 1 ELSE 0 END;
    EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] TotalCount reports full match count, not page size',
        @Expected = N'1', @Actual = @n;
END

DROP TABLE #LS;
GO
```

- [ ] **Step 4: Write the signature-parity test**

The guard against the key-drift risk in spec §3.1(b) — a filter name present in the proc but not the NQ (or vice versa) goes silently inert. This also pins `Lot_Search` as frozen.

Create `sql/tests/0067_Lot_SearchAdvanced/050_signature_parity.sql`:

```sql
-- =============================================
-- File:         0067_Lot_SearchAdvanced/050_signature_parity.sql
-- Author:       Blue Ridge Automation
-- Description:  The proc must expose EXACTLY the 12 canonical filter parameters
--               (design spec section 3.1). The named query's parameters[] and
--               BlueRidge.Lots.Lot._EMPTY_FILTERS carry the same twelve names;
--               this pins the SQL end so drift is caught here rather than as a
--               filter that silently stops filtering. Also asserts Lot_Search
--               is still frozen at its original four parameters.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/050_signature_parity.sql';
GO

DECLARE @n INT;
DECLARE @Expected TABLE (Name SYSNAME PRIMARY KEY);
INSERT INTO @Expected (Name) VALUES
    (N'@Query'), (N'@ItemId'), (N'@CreatedFromEt'), (N'@CreatedToEt'),
    (N'@ToolId'), (N'@ToolCavityId'), (N'@LocationId'), (N'@MachineLocationId'),
    (N'@ShiftId'), (N'@LotStatusId'), (N'@LotOriginTypeId'), (N'@LimitRows');

SELECT @n = COUNT(*) FROM sys.parameters
WHERE object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced');
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] proc exposes exactly 12 parameters',
    @Expected = N'12', @Actual = @n;

SELECT @n = COUNT(*) FROM sys.parameters p
WHERE p.object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced')
  AND p.name NOT IN (SELECT Name FROM @Expected);
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] no unexpected parameter name',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM @Expected e
WHERE e.Name NOT IN (SELECT p.name FROM sys.parameters p
                     WHERE p.object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced'));
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] no canonical parameter missing',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID(N'Lots.Lot_Search');
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] Lot_Search still has exactly 4 parameters (frozen)',
    @Expected = N'4', @Actual = @n;
GO
```

- [ ] **Step 5: Run all five files in `0067`**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0067"
```

Expected: PASS. Grep for both `FAIL` and `ERROR running`.

- [ ] **Step 6: Commit**

```bash
git add sql/tests/0067_Lot_SearchAdvanced/020_date_boundary.sql sql/tests/0067_Lot_SearchAdvanced/030_origin_conditional.sql sql/tests/0067_Lot_SearchAdvanced/040_total_count.sql sql/tests/0067_Lot_SearchAdvanced/050_signature_parity.sql
git commit -m "test(sql): Lot_SearchAdvanced boundary, origin, TotalCount and signature parity"
```

---

## Task 3: `Lots.SerializedPart_GetTraceDetail`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_SerializedPart_GetTraceDetail.sql`
- Test: `sql/tests/0068_Trace_Detail_Reads/010_serial_detail.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Lots.SerializedPart_GetTraceDetail @SerialNumber NVARCHAR(50)`. Result: `SerialNumber, ItemId, ItemPartNumber, ProducingLotId, ProducingLotName, EtchedAt, ProducedAt, OperatorName, MachineName, ContainerId, ContainerStatusCode, AimShipperId, CompletedAt`. Zero rows when the serial is unknown.

**Context:** `Lots.SerializedPart` is `Id, SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId` with `UQ_SerializedPart_SerialNumber`. Container link is `Lots.ContainerSerial`; Honda identifier is `Lots.ShippingLabel.AimShipperId`. Operator display name is `Location.AppUser.DisplayName NVARCHAR(200) NOT NULL` — verified present.

**There is no ship-date column in the schema** (spec §2.5). Return `Container.CompletedAt` aliased `CompletedAt`. **Do not alias it to anything containing "ship"** — the view labels it *Completed*, and mislabelling container-close time as ship time would misreport Honda traceability data.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0068_Trace_Detail_Reads/010_serial_detail.sql`:

```sql
-- =============================================
-- File:         0068_Trace_Detail_Reads/010_serial_detail.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-002 serial trace payload.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0068_Trace_Detail_Reads/010_serial_detail.sql';
GO

CREATE TABLE #SD (
    SerialNumber NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(100),
    ProducingLotId BIGINT, ProducingLotName NVARCHAR(50),
    EtchedAt DATETIME2(3), ProducedAt DATETIME2(3),
    OperatorName NVARCHAR(200), MachineName NVARCHAR(200),
    ContainerId BIGINT, ContainerStatusCode NVARCHAR(50),
    AimShipperId NVARCHAR(50), CompletedAt DATETIME2(3)
);

DECLARE @n INT, @Serial NVARCHAR(50);

INSERT INTO #SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = N'NO-SUCH-SERIAL-ZZZ';
SELECT @n = COUNT(*) FROM #SD;
EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] unknown serial returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #SD;

SELECT TOP (1) @Serial = SerialNumber FROM Lots.SerializedPart ORDER BY Id;

IF @Serial IS NULL
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] known-serial test skipped -- no SerializedPart seeded',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    INSERT INTO #SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = @Serial;
    SELECT @n = COUNT(*) FROM #SD;
    EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] known serial returns exactly one row',
        @Expected = N'1', @Actual = @n;

    SELECT @n = COUNT(*) FROM #SD WHERE ProducingLotId IS NULL OR ItemPartNumber IS NULL;
    EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] producing LOT and part number populated',
        @Expected = N'0', @Actual = @n;
END

DROP TABLE #SD;
GO
```

- [ ] **Step 2: Run and verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0068"
```

Expected: FAIL — `Could not find stored procedure 'Lots.SerializedPart_GetTraceDetail'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_SerializedPart_GetTraceDetail.sql`:

```sql
-- =============================================
-- Repeatable:  R__Lots_SerializedPart_GetTraceDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-002 Serialized Item Search payload, rendered as a detail
--              panel on Global Trace. One result set (FDS-11-011); empty set
--              means the serial is unknown.
--
--              CompletedAt is Lots.Container.CompletedAt -- container CLOSE
--              time. The schema has NO ship timestamp (design spec 2.5); the
--              view labels this column "Completed", never "Ship date".
-- =============================================
CREATE OR ALTER PROCEDURE Lots.SerializedPart_GetTraceDetail
    @SerialNumber NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sp.SerialNumber,
        sp.ItemId,
        i.PartNumber AS ItemPartNumber,
        sp.ProducingLotId,
        l.LotName    AS ProducingLotName,
        CAST(sp.EtchedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EtchedAt,
        CAST(pe.EventAt  AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ProducedAt,
        op.DisplayName   AS OperatorName,
        term.Name        AS MachineName,
        cs.ContainerId,
        csc.Code         AS ContainerStatusCode,
        lbl.AimShipperId,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt
    FROM Lots.SerializedPart sp
    INNER JOIN Parts.Item i ON i.Id = sp.ItemId
    INNER JOIN Lots.Lot   l ON l.Id = sp.ProducingLotId
    OUTER APPLY (
        SELECT TOP (1) pe2.EventAt, pe2.AppUserId, pe2.TerminalLocationId
        FROM Workorder.ProductionEvent pe2
        WHERE pe2.LotId = sp.ProducingLotId
        ORDER BY pe2.EventAt DESC, pe2.Id DESC
    ) pe
    LEFT JOIN Location.AppUser  op   ON op.Id   = pe.AppUserId
    LEFT JOIN Location.Location term ON term.Id = pe.TerminalLocationId
    LEFT JOIN Lots.ContainerSerial cs ON cs.SerializedPartId = sp.Id
    LEFT JOIN Lots.Container       c  ON c.Id  = cs.ContainerId
    LEFT JOIN Lots.ContainerStatusCode csc ON csc.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        SELECT TOP (1) sl.AimShipperId
        FROM Lots.ShippingLabel sl
        WHERE sl.ContainerId = cs.ContainerId AND sl.IsVoid = 0
        ORDER BY sl.CreatedAt DESC, sl.Id DESC
    ) lbl
    WHERE sp.SerialNumber = @SerialNumber;
END
GO
```

- [ ] **Step 4: Run and verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0068"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_SerializedPart_GetTraceDetail.sql sql/tests/0068_Trace_Detail_Reads/010_serial_detail.sql
git commit -m "feat(sql): SerializedPart_GetTraceDetail for FDS-12-002"
```

---

## Task 4: Container trace reads — detail, serial list, hold history

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql`
- Create: `sql/migrations/repeatable/R__Lots_Container_ListSerials.sql`
- Create: `sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql`
- Test: `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Lots.Container_GetTraceDetail @ContainerId BIGINT` → `ContainerId, ItemId, ItemPartNumber, ContainerStatusCode, PieceCount, SerialCount, SourceLotCount, OpenedAt, CompletedAt, AimShipperId, OpenHoldCount, TotalHoldCount`.
  - `Lots.Container_ListSerials @ContainerId BIGINT` → `SerializedPartId, SerialNumber, TrayPosition, ProducingLotId, ProducingLotName`.
  - `Quality.Hold_ListByContainer @ContainerId BIGINT` → `HoldEventId, HoldTypeCode, HoldTypeName, Reason, PlacedByName, PlacedAt, ReleasedByName, ReleasedAt, ReleaseRemarks, IsOpen`.

**Context:** Piece count sums `Lots.ContainerTray.PartsClosedCount`. Source LOTs are counted the way `GlobalTrace_Resolve` expands a container: `ContainerTray.FinishedGoodLotId` (migration `0034`) UNIONed with `ContainerSerial → SerializedPart.ProducingLotId`. `Quality.HoldEvent` carries `ContainerId` under `CK_HoldEvent_LotXorContainer` — a row is Lot-scoped **or** Container-scoped, never both. Open hold = `ReleasedAt IS NULL`.

Three procs because one proc returns one result set.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql`:

```sql
-- =============================================
-- File:         0068_Trace_Detail_Reads/020_container_detail.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-003 container trace payload + its two sibling reads.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0068_Trace_Detail_Reads/020_container_detail.sql';
GO

CREATE TABLE #CD (
    ContainerId BIGINT, ItemId BIGINT, ItemPartNumber NVARCHAR(100),
    ContainerStatusCode NVARCHAR(50), PieceCount INT, SerialCount INT,
    SourceLotCount INT, OpenedAt DATETIME2(3), CompletedAt DATETIME2(3),
    AimShipperId NVARCHAR(50), OpenHoldCount INT, TotalHoldCount INT
);
CREATE TABLE #CS (
    SerializedPartId BIGINT, SerialNumber NVARCHAR(50), TrayPosition INT,
    ProducingLotId BIGINT, ProducingLotName NVARCHAR(50)
);
CREATE TABLE #CH (
    HoldEventId BIGINT, HoldTypeCode NVARCHAR(50), HoldTypeName NVARCHAR(100),
    Reason NVARCHAR(500), PlacedByName NVARCHAR(200), PlacedAt DATETIME2(3),
    ReleasedByName NVARCHAR(200), ReleasedAt DATETIME2(3),
    ReleaseRemarks NVARCHAR(500), IsOpen INT
);

DECLARE @n INT, @ContainerId BIGINT;

INSERT INTO #CD EXEC Lots.Container_GetTraceDetail @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CD;

INSERT INTO #CS EXEC Lots.Container_ListSerials @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CS;
EXEC test.Assert_IsEqual @TestName = N'[ContainerSerials] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CS;

INSERT INTO #CH EXEC Quality.Hold_ListByContainer @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CH;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CH;

SELECT TOP (1) @ContainerId = Id FROM Lots.Container ORDER BY Id;

IF @ContainerId IS NULL
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] known-container tests skipped -- no Container seeded',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    INSERT INTO #CD EXEC Lots.Container_GetTraceDetail @ContainerId = @ContainerId;
    SELECT @n = COUNT(*) FROM #CD;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] known container returns exactly one row',
        @Expected = N'1', @Actual = @n;

    SELECT @n = COUNT(*) FROM #CD WHERE ItemPartNumber IS NULL OR ContainerStatusCode IS NULL;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] part number and status populated',
        @Expected = N'0', @Actual = @n;

    SELECT @n = COUNT(*) FROM #CD
    WHERE PieceCount IS NULL OR SerialCount IS NULL OR SourceLotCount IS NULL
       OR OpenHoldCount IS NULL OR TotalHoldCount IS NULL;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] derived counts are never NULL',
        @Expected = N'0', @Actual = @n;

    DECLARE @DeclaredSerials INT, @ListedSerials INT;
    SELECT @DeclaredSerials = MAX(SerialCount) FROM #CD;
    INSERT INTO #CS EXEC Lots.Container_ListSerials @ContainerId = @ContainerId;
    SELECT @ListedSerials = COUNT(*) FROM #CS;
    SET @n = CASE WHEN @DeclaredSerials = @ListedSerials THEN 1 ELSE 0 END;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] SerialCount matches Container_ListSerials',
        @Expected = N'1', @Actual = @n;

    DECLARE @DeclaredHolds INT, @ListedHolds INT;
    SELECT @DeclaredHolds = MAX(TotalHoldCount) FROM #CD;
    INSERT INTO #CH EXEC Quality.Hold_ListByContainer @ContainerId = @ContainerId;
    SELECT @ListedHolds = COUNT(*) FROM #CH;
    SET @n = CASE WHEN @DeclaredHolds = @ListedHolds THEN 1 ELSE 0 END;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] TotalHoldCount matches Hold_ListByContainer',
        @Expected = N'1', @Actual = @n;
END

DROP TABLE #CD;
DROP TABLE #CS;
DROP TABLE #CH;
GO
```

- [ ] **Step 2: Run and verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0068"
```

Expected: FAIL — `Could not find stored procedure 'Lots.Container_GetTraceDetail'`.

- [ ] **Step 3: Write `Container_GetTraceDetail`**

Create `sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql`:

```sql
-- =============================================
-- Repeatable:  R__Lots_Container_GetTraceDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-003 Container Search payload, rendered as a detail panel
--              on Global Trace. One result set (FDS-11-011); empty set means
--              the container is unknown. The serial list and hold history are
--              sibling procs -- one proc, one result set.
--
--              Containers have no name column; identity is the container Id and
--              the AIM shipper Id on the Honda label (design spec 2.4).
--              CompletedAt is container CLOSE time, not ship time (spec 2.5).
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Container_GetTraceDetail
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Id AS ContainerId,
        c.ItemId,
        i.PartNumber AS ItemPartNumber,
        csc.Code     AS ContainerStatusCode,
        ISNULL(tray.PieceCount, 0)    AS PieceCount,
        ISNULL(ser.SerialCount, 0)    AS SerialCount,
        ISNULL(src.SourceLotCount, 0) AS SourceLotCount,
        CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt,
        lbl.AimShipperId,
        ISNULL(h.OpenHoldCount, 0)  AS OpenHoldCount,
        ISNULL(h.TotalHoldCount, 0) AS TotalHoldCount
    FROM Lots.Container c
    INNER JOIN Parts.Item i ON i.Id = c.ItemId
    INNER JOIN Lots.ContainerStatusCode csc ON csc.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        SELECT SUM(ct.PartsClosedCount) AS PieceCount
        FROM Lots.ContainerTray ct WHERE ct.ContainerId = c.Id
    ) tray
    OUTER APPLY (
        SELECT COUNT(*) AS SerialCount
        FROM Lots.ContainerSerial cs WHERE cs.ContainerId = c.Id
    ) ser
    OUTER APPLY (
        SELECT COUNT(*) AS SourceLotCount FROM (
            SELECT ct.FinishedGoodLotId AS LotId
            FROM Lots.ContainerTray ct
            WHERE ct.ContainerId = c.Id AND ct.FinishedGoodLotId IS NOT NULL
            UNION
            SELECT sp.ProducingLotId
            FROM Lots.ContainerSerial cs
            INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
            WHERE cs.ContainerId = c.Id
        ) u
    ) src
    OUTER APPLY (
        SELECT TOP (1) sl.AimShipperId
        FROM Lots.ShippingLabel sl
        WHERE sl.ContainerId = c.Id AND sl.IsVoid = 0
        ORDER BY sl.CreatedAt DESC, sl.Id DESC
    ) lbl
    OUTER APPLY (
        SELECT COUNT(*) AS TotalHoldCount,
               SUM(CASE WHEN he.ReleasedAt IS NULL THEN 1 ELSE 0 END) AS OpenHoldCount
        FROM Quality.HoldEvent he WHERE he.ContainerId = c.Id
    ) h
    WHERE c.Id = @ContainerId;
END
GO
```

- [ ] **Step 4: Write `Container_ListSerials`**

Create `sql/migrations/repeatable/R__Lots_Container_ListSerials.sql`:

```sql
-- =============================================
-- Repeatable:  R__Lots_Container_ListSerials.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: Sibling read to Lots.Container_GetTraceDetail -- the container's
--              serialized parts, in tray-position order. Separate proc because
--              one proc returns one result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Container_ListSerials
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sp.Id AS SerializedPartId,
        sp.SerialNumber,
        cs.TrayPosition,
        sp.ProducingLotId,
        l.LotName AS ProducingLotName
    FROM Lots.ContainerSerial cs
    INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
    INNER JOIN Lots.Lot            l  ON l.Id  = sp.ProducingLotId
    WHERE cs.ContainerId = @ContainerId
    ORDER BY cs.TrayPosition, sp.SerialNumber;
END
GO
```

- [ ] **Step 5: Write `Quality.Hold_ListByContainer`**

Create `sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql`:

```sql
-- =============================================
-- Repeatable:  R__Quality_Hold_ListByContainer.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-003 hold HISTORY for a container -- open AND released,
--              newest first. Distinct from Quality.Hold_GetOpenByContainer,
--              which filters ReleasedAt IS NULL and therefore cannot show
--              history. One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Hold_ListByContainer
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        he.Id AS HoldEventId,
        htc.Code AS HoldTypeCode,
        htc.Name AS HoldTypeName,
        he.Reason,
        placed.DisplayName AS PlacedByName,
        CAST(he.PlacedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PlacedAt,
        rel.DisplayName AS ReleasedByName,
        CAST(he.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReleasedAt,
        he.ReleaseRemarks,
        CASE WHEN he.ReleasedAt IS NULL THEN 1 ELSE 0 END AS IsOpen
    FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode htc    ON htc.Id    = he.HoldTypeCodeId
    INNER JOIN Location.AppUser     placed ON placed.Id = he.PlacedByUserId
    LEFT  JOIN Location.AppUser     rel    ON rel.Id    = he.ReleasedByUserId
    WHERE he.ContainerId = @ContainerId
    ORDER BY he.PlacedAt DESC, he.Id DESC;
END
GO
```

- [ ] **Step 6: Run the trace tests**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter "0068"
```

Expected: PASS.

- [ ] **Step 7: Run the FULL suite for regressions**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter ""
```

Expected: exit 0, no failed assertions. **This is the evidence that `Lot_Search` stayed frozen** — `077_Lot_Search.sql` must still pass untouched. Grep for both `FAIL` and `ERROR running`.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql sql/migrations/repeatable/R__Lots_Container_ListSerials.sql sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql
git commit -m "feat(sql): container trace detail, serial list and hold history for FDS-12-003"
```

---

## Task 5: Named queries

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/lots/Lot_SearchAdvanced/{query.sql,resource.json}`
- Create: `.../lots/SerializedPart_GetTraceDetail/{query.sql,resource.json}`
- Create: `.../lots/Container_GetTraceDetail/{query.sql,resource.json}`
- Create: `.../lots/Container_ListSerials/{query.sql,resource.json}`
- Create: `.../quality/Hold_ListByContainer/{query.sql,resource.json}`

**Interfaces:**
- Consumes: the five procs from Tasks 1, 3, 4.
- Produces: named queries `lots/Lot_SearchAdvanced`, `lots/SerializedPart_GetTraceDetail`, `lots/Container_GetTraceDetail`, `lots/Container_ListSerials`, `quality/Hold_ListByContainer`.

**Context:** `lots/Lot_Search` is **frozen** — do not touch it. `sqlType` is Designer's enum: `3` = BIGINT, `7` = String, `8` = DateTime, `2` = Int4. `version: 2` is mandatory (Designer 8.3.5 NPEs on v1). `attributes.type` is `"Query"`.

- [ ] **Step 1: Create the `Lot_SearchAdvanced` query**

`.../lots/Lot_SearchAdvanced/query.sql`:

```sql
EXEC Lots.Lot_SearchAdvanced
    @Query             = :query,
    @ItemId            = :itemId,
    @CreatedFromEt     = :createdFromEt,
    @CreatedToEt       = :createdToEt,
    @ToolId            = :toolId,
    @ToolCavityId      = :toolCavityId,
    @LocationId        = :locationId,
    @MachineLocationId = :machineLocationId,
    @ShiftId           = :shiftId,
    @LotStatusId       = :lotStatusId,
    @LotOriginTypeId   = :lotOriginTypeId,
    @LimitRows         = :limitRows
```

`.../lots/Lot_SearchAdvanced/resource.json`:

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
      "timestamp": "2026-08-25T12:00:00Z"
    },
    "parameters": [
      { "type": "Parameter", "identifier": "query",             "sqlType": 7 },
      { "type": "Parameter", "identifier": "itemId",            "sqlType": 3 },
      { "type": "Parameter", "identifier": "createdFromEt",     "sqlType": 8 },
      { "type": "Parameter", "identifier": "createdToEt",       "sqlType": 8 },
      { "type": "Parameter", "identifier": "toolId",            "sqlType": 3 },
      { "type": "Parameter", "identifier": "toolCavityId",      "sqlType": 3 },
      { "type": "Parameter", "identifier": "locationId",        "sqlType": 3 },
      { "type": "Parameter", "identifier": "machineLocationId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "shiftId",           "sqlType": 3 },
      { "type": "Parameter", "identifier": "lotStatusId",       "sqlType": 3 },
      { "type": "Parameter", "identifier": "lotOriginTypeId",   "sqlType": 3 },
      { "type": "Parameter", "identifier": "limitRows",         "sqlType": 2 }
    ]
  }
}
```

- [ ] **Step 2: Create the four single-parameter queries**

`.../lots/SerializedPart_GetTraceDetail/query.sql`:

```sql
EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = :serialNumber
```

`.../lots/Container_GetTraceDetail/query.sql`:

```sql
EXEC Lots.Container_GetTraceDetail @ContainerId = :containerId
```

`.../lots/Container_ListSerials/query.sql`:

```sql
EXEC Lots.Container_ListSerials @ContainerId = :containerId
```

`.../quality/Hold_ListByContainer/query.sql`:

```sql
EXEC Quality.Hold_ListByContainer @ContainerId = :containerId
```

Each `resource.json` is byte-identical to the Step 1 file except for the `parameters` array. For `SerializedPart_GetTraceDetail`:

```json
    "parameters": [
      { "type": "Parameter", "identifier": "serialNumber", "sqlType": 7 }
    ]
```

For the other three:

```json
    "parameters": [
      { "type": "Parameter", "identifier": "containerId", "sqlType": 3 }
    ]
```

- [ ] **Step 3: Scan the gateway**

```bash
powershell -File scan.ps1
```

Expected: completes without error. A 403 means the POST is missing `Content-Type: application/json` or `X-Ignition-API-Token`; a 401 means a bad token.

- [ ] **Step 4: Verify each query resolves**

In the Designer script console:

```python
print system.db.runNamedQuery("lots/Container_ListSerials", {"containerId": -1}).getRowCount()
print system.db.runNamedQuery("quality/Hold_ListByContainer", {"containerId": -1}).getRowCount()
print system.db.runNamedQuery("lots/Container_GetTraceDetail", {"containerId": -1}).getRowCount()
```

Expected: `0` from each — the query resolves and returns an empty dataset. An exception naming the query means it did not deploy; check `wrapper.log` for `Named query not found`.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_SearchAdvanced ignition/projects/Core/ignition/named-query/lots/SerializedPart_GetTraceDetail ignition/projects/Core/ignition/named-query/lots/Container_GetTraceDetail ignition/projects/Core/ignition/named-query/lots/Container_ListSerials ignition/projects/Core/ignition/named-query/quality/Hold_ListByContainer
git commit -m "feat(ignition): named queries for Lot_SearchAdvanced and the trace detail reads"
```

---

## Task 6: Entity scripts

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (append)
- Modify: `.../BlueRidge/Lots/SerializedPart/code.py` (append)
- Modify: `.../BlueRidge/Lots/Container/code.py` (append)
- Modify: `.../BlueRidge/Lots/GlobalTrace/code.py` (append)

**Interfaces:**
- Consumes: the five named queries from Task 5.
- Produces:
  - `BlueRidge.Lots.Lot._EMPTY_FILTERS` — the canonical 12-key filter shape; `emptyFilters()` returns a copy.
  - `BlueRidge.Lots.Lot.searchAdvanced(filters=None)` → `list[dict]`.
  - `BlueRidge.Lots.Lot.exportCsv(rows)` → triggers a browser download; returns `None`.
  - `BlueRidge.Lots.SerializedPart._EMPTY_TRACE_DETAIL`, `getTraceDetail(serialNumber)`, `getTraceDetailOrEmpty(serialNumber)`.
  - `BlueRidge.Lots.Container._EMPTY_TRACE_DETAIL`, `getTraceDetail(containerId)`, `getTraceDetailOrEmpty(containerId)`, `listSerials(containerId)`, `listHolds(containerId)`.
  - `BlueRidge.Lots.GlobalTrace.loadDetail(matchType, matchedEntityId, serialNumber=None)` → dict with keys `serialDetail`, `containerDetail`, `containerSerials`, `containerHolds`.

**Context — the three rules this task exists to satisfy:**

1. **`searchAdvanced` takes ONE argument, a dict.** There is no twelve-positional-argument signature to mis-order. `HoldManagement` already calls the *frozen* `search()` positionally; the new function must not repeat that shape.
2. **`Lot.search()` is frozen.** Append only — do not edit it.
3. **Binding-bound reads return a fully-shaped dict on the not-found path**, never `None` — a `None` replaces the view's shaped default and every nested read then errors.

- [ ] **Step 1: Append to `BlueRidge/Lots/Lot/code.py`**

```python
_EMPTY_FILTERS = {
    "query": None, "itemId": None, "createdFromEt": None, "createdToEt": None,
    "toolId": None, "toolCavityId": None, "locationId": None,
    "machineLocationId": None, "shiftId": None, "lotStatusId": None,
    "lotOriginTypeId": None, "limitRows": 100,
}


def emptyFilters():
    """The canonical FDS-12-004 filter shape. The view seeds view.custom.filters
       from this and Reset reseeds from it; searchAdvanced fills gaps from it.
       One source of truth for the twelve names (design spec section 3.1)."""
    return dict(_EMPTY_FILTERS)


def _toSqlDate(value):
    """ia.input.date-time-input hands back a millisecond timestamp, not a
       string. Floor it to the session-timezone day so the proc's DATE
       parameter gets a clean calendar day. None/blank passes through as None.

       system.date.* raises Java throwables, which a bare `except Exception`
       does NOT catch in Jython -- hence the two-arm guard."""
    value = _u(value)
    if value is None or value == "":
        return None
    try:
        return system.date.midnight(value)
    except (Exception, java.lang.Exception):
        BlueRidge.Common.Util.log("un-coercible date value=%s" % (value,))
        return None


def searchAdvanced(filters=None):
    """FDS-12-004 filtered LOT browse. ONE argument -- a dict shaped like
       _EMPTY_FILTERS. Absent keys fall back to the default (no filter);
       unknown keys are ignored. Deliberately NOT twelve positional args:
       positional drift is the real hazard here, not the parameter count
       (design spec section 3.1a).

       Returns list[dict]; [] when nothing matches."""
    filters = _u(filters) or {}
    params = dict(_EMPTY_FILTERS)
    for key in _EMPTY_FILTERS:
        if key in filters:
            params[key] = _u(filters[key])
    params["createdFromEt"] = _toSqlDate(params["createdFromEt"])
    params["createdToEt"] = _toSqlDate(params["createdToEt"])
    if not params["limitRows"]:
        params["limitRows"] = 100
    BlueRidge.Common.Util.log("params=%s" % params)
    return BlueRidge.Common.Db.execList("lots/Lot_SearchAdvanced", params)


def exportCsv(rows):
    """FRS 3.5.10 -- export the current filtered result set as CSV. No-op with
       an info toast when there is nothing to export."""
    rows = _u(rows) or []
    if not rows:
        BlueRidge.Common.Notify.toast("Nothing to export", "Run a search first.", "info")
        return
    ds = system.dataset.toDataSet(rows)
    system.perspective.download("lot-search.csv", system.dataset.toCSV(ds))
```

> `import java.lang` must be present at the top of the module for the two-arm `except` guard — Jython's bare `except Exception` does **not** catch Java throwables, and `system.date.*` raises those on a bad value. If the import is absent, add it.

- [ ] **Step 2: Append to `BlueRidge/Lots/SerializedPart/code.py`**

```python
_EMPTY_TRACE_DETAIL = {
    "SerialNumber": None, "ItemId": None, "ItemPartNumber": None,
    "ProducingLotId": None, "ProducingLotName": None, "EtchedAt": None,
    "ProducedAt": None, "OperatorName": None, "MachineName": None,
    "ContainerId": None, "ContainerStatusCode": None, "AimShipperId": None,
    "CompletedAt": None,
}


def getTraceDetail(serialNumber):
    """FDS-12-002 payload for one serial. Returns dict, or None when unknown.

       CompletedAt is container CLOSE time -- the schema has no ship timestamp
       (design spec 2.5). The view labels it "Completed", never "Ship date"."""
    BlueRidge.Common.Util.log("serialNumber=%s" % serialNumber)
    return BlueRidge.Common.Db.execOne(
        "lots/SerializedPart_GetTraceDetail", {"serialNumber": serialNumber})


def getTraceDetailOrEmpty(serialNumber):
    """Binding-safe variant: ALWAYS the fully-shaped dict. A None return would
       replace the view's shaped default and make every nested read error."""
    return getTraceDetail(serialNumber) or dict(_EMPTY_TRACE_DETAIL)
```

- [ ] **Step 3: Append to `BlueRidge/Lots/Container/code.py`**

```python
_EMPTY_TRACE_DETAIL = {
    "ContainerId": None, "ItemId": None, "ItemPartNumber": None,
    "ContainerStatusCode": None, "PieceCount": 0, "SerialCount": 0,
    "SourceLotCount": 0, "OpenedAt": None, "CompletedAt": None,
    "AimShipperId": None, "OpenHoldCount": 0, "TotalHoldCount": 0,
}


def getTraceDetail(containerId):
    """FDS-12-003 payload for one container. Returns dict, or None when unknown.

       CompletedAt is container CLOSE time -- the schema has no ship timestamp
       (design spec 2.5). The view labels it "Completed", never "Ship date"."""
    BlueRidge.Common.Util.log("containerId=%s" % containerId)
    return BlueRidge.Common.Db.execOne(
        "lots/Container_GetTraceDetail", {"containerId": containerId})


def getTraceDetailOrEmpty(containerId):
    """Binding-safe variant: ALWAYS the fully-shaped dict."""
    return getTraceDetail(containerId) or dict(_EMPTY_TRACE_DETAIL)


def listSerials(containerId):
    """The container's serialized parts, tray-position order. [] when none."""
    return BlueRidge.Common.Db.execList(
        "lots/Container_ListSerials", {"containerId": containerId}) or []


def listHolds(containerId):
    """Full hold HISTORY (open and released), newest first. [] when none.
       Distinct from the open-only Quality.Hold_GetOpenByContainer."""
    return BlueRidge.Common.Db.execList(
        "quality/Hold_ListByContainer", {"containerId": containerId}) or []
```

- [ ] **Step 4: Append the dispatcher to `BlueRidge/Lots/GlobalTrace/code.py`**

```python
def loadDetail(matchType, matchedEntityId, serialNumber=None):
    """Dispatch a resolver hit to its entity-specific detail payload. Returns
       every key the Global Trace panels bind, always fully shaped, so the
       caller can assign each block in one property write.

       'Shipper' routes to the container panel via the label's container --
       MatchedEntityId is the ShippingLabel row for that match type."""
    matchType = _u(matchType)
    matchedEntityId = _u(matchedEntityId)
    BlueRidge.Common.Util.log("matchType=%s entityId=%s" % (matchType, matchedEntityId))

    out = {
        "serialDetail": dict(BlueRidge.Lots.SerializedPart._EMPTY_TRACE_DETAIL),
        "containerDetail": dict(BlueRidge.Lots.Container._EMPTY_TRACE_DETAIL),
        "containerSerials": [],
        "containerHolds": [],
    }

    containerId = None

    if matchType == "Serial":
        out["serialDetail"] = BlueRidge.Lots.SerializedPart.getTraceDetailOrEmpty(
            _u(serialNumber))
        containerId = out["serialDetail"].get("ContainerId")
    elif matchType == "Container":
        containerId = matchedEntityId
    elif matchType == "Shipper":
        row = BlueRidge.Common.Db.execOne(
            "lots/ShippingLabel_GetById", {"shippingLabelId": matchedEntityId})
        containerId = row.get("ContainerId") if row else None

    if containerId:
        out["containerDetail"] = BlueRidge.Lots.Container.getTraceDetailOrEmpty(containerId)
        out["containerSerials"] = BlueRidge.Lots.Container.listSerials(containerId)
        out["containerHolds"] = BlueRidge.Lots.Container.listHolds(containerId)
    return out
```

> **Verify before relying on it:** the proc `Lots.ShippingLabel_GetById` exists. Confirm the named query `lots/ShippingLabel_GetById` also exists and returns a `ContainerId` column (`ls ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetById`). If the NQ is missing, create it in Task 5's exact `resource.json` shape with a single `shippingLabelId` parameter (`sqlType: 3`) and `query.sql` of `EXEC Lots.ShippingLabel_GetById @Id = :shippingLabelId` — matching the proc's actual parameter name.

- [ ] **Step 5: Scan and smoke-test from the script console**

```bash
powershell -File scan.ps1
```

Then in the Designer script console:

```python
print len(BlueRidge.Lots.Lot.searchAdvanced({"limitRows": 5}))
print BlueRidge.Lots.Container.getTraceDetailOrEmpty(-1)["PieceCount"]
print sorted(BlueRidge.Lots.GlobalTrace.loadDetail("Container", -1).keys())
print len(BlueRidge.Lots.Lot.search(None, 1))
```

Expected: a row count with no exception; `0`; `['containerDetail', 'containerHolds', 'containerSerials', 'serialDetail']`; and the last line — the **frozen** `HoldManagement` call shape — returning without error.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/SerializedPart/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/GlobalTrace/code.py
git commit -m "feat(ignition): entity-script layer for LOT Search Advanced and trace detail panels"
```

---

## Task 7: Extend the LOT Search view — **Designer**

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotSearch/view.json` — **in Designer**

**Interfaces:**
- Consumes: `BlueRidge.Lots.Lot.emptyFilters()`, `searchAdvanced(filters)`, `exportCsv(rows)` from Task 6.
- Produces: nothing consumed later.

**Context:** the view already has `QueryInput`, `StatusDropdown`, `OriginDropdown`, `SearchButton`, `ResetButton` and `ResultsTable` under `SearchBar` / `ResultsPanel`, plus a root `search()` custom method. Extend it — do not rebuild.

- [ ] **Step 1: Reset the pickled result data**

`custom.results` holds 33 live Dev rows saved as the property default. Set it to `[]`.

```bash
git diff --stat ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotSearch/view.json
```

Expected: a diff that *removes* lines. A large diff for a small change means Designer re-pickled live data — investigate before continuing.

- [ ] **Step 2: Seed the filter state**

Add to the view's `custom` block, every key present, matching `_EMPTY_FILTERS`:

```json
"filters": {
  "query": null,
  "itemId": null,
  "createdFromEt": null,
  "createdToEt": null,
  "toolId": null,
  "toolCavityId": null,
  "locationId": null,
  "machineLocationId": null,
  "shiftId": null,
  "lotStatusId": null,
  "lotOriginTypeId": null,
  "limitRows": 100
}
```

Every `view.custom.*` a binding traverses needs a fully-shaped default, or the first paint renders a Component Error. The existing `query` / `statusId` / `originId` props stay for now; bind the new controls to `filters.*` and migrate the three old ones onto `filters.query` / `filters.lotStatusId` / `filters.lotOriginTypeId` so there is one filter object, not two sources.

- [ ] **Step 3: Add the eight filter controls**

In `SearchBar`, each following the existing `<Name>Field` pattern (label + input in a flex container):

| Control | Component | Bidirectional bind |
|---|---|---|
| `PartField` | `ia.input.dropdown` | `view.custom.filters.itemId` |
| `CreatedFromField` | `ia.input.date-time-input` | `view.custom.filters.createdFromEt` |
| `CreatedToField` | `ia.input.date-time-input` | `view.custom.filters.createdToEt` |
| `DieField` | `ia.input.dropdown` | `view.custom.filters.toolId` |
| `CavityField` | `ia.input.dropdown` | `view.custom.filters.toolCavityId` |
| `LocationField` | `ia.input.dropdown` | `view.custom.filters.locationId` |
| `MachineField` | `ia.input.dropdown` | `view.custom.filters.machineLocationId` |
| `ShiftField` | `ia.input.dropdown` | `view.custom.filters.shiftId` |

Group `DieField`, `CavityField`, `MachineField`, `ShiftField` in a flex container `DieCastOriginGroup` labelled **`Die Cast origin`** — those four implicitly narrow to die-cast-origin LOTs, and the caption is what tells the operator why.

Component rules that bite here:
- `"bidirectional": true` goes **inside** the binding's `config` block — outside it, the binding is silently one-way.
- Dropdown `options` are `{label, value}` objects **only** — a `code` or `name` key breaks the component. A placeholder is an **object** (`{text, color, icon}`), not a string.
- `date-time-input` `props.format` uses **Moment.js** tokens: `"YYYY-MM-DD"`. (`"yyyy-MM-dd"` renders `2026-04-Tu` — lowercase `dd` is day-of-week.) Its `props.value` is a **numeric millisecond timestamp**, which is why `filters.createdFromEt` defaults to `null` and never to a date string.
- Set `deferUpdates: false` on `QueryInput` — a text field commits its bound value on blur, and a button reading it before the commit lands gets an empty string and silently searches for nothing.

- [ ] **Step 4: Add the three visible columns AND the hidden `Id` column**

Add to `ResultsTable.props.columns`:

| `field` | `header.title` | `visible` |
|---|---|---|
| `ToolCode` | `Die` | `true` |
| `CavityNumber` | `Cavity` | `true` |
| `OriginMachineName` | `Machine` | `true` |
| `Id` | `Id` | **`false`** |

**The hidden `Id` column is mandatory, not cosmetic.** `selection.data` is built from the table's `columns`, not the raw row — a field with no column entry is **absent** from every selection dict. Without this column, `selection.data[0]["Id"]` raises `KeyError` and row-click navigation cannot work at all.

Every column entry needs the **full ~25-key schema**; `header` is an object (`{title, justify, align, style}`), never a bare string — a string there breaks the whole table. Copy an existing column object from the same array and change `field`, `header.title`, `width`, `visible`.

- [ ] **Step 5: Wire row-click navigation**

On `ResultsTable`, add an **`onSelectionChange`** event script (`onRowClick` does not exist on `ia.display.table` and fails silently):

```python
	sel = self.props.selection.data
	if sel is None or len(sel) == 0:
		return
	system.perspective.navigate(page='/shop-floor/lot-detail/%d' % int(sel[0]['Id']))
```

Three things to get right: the body starts with a **tab** (Designer wraps it in `def runAction(self, event):`; a column-0 body is an `IndentationError`); the guard is `if sel is None`, never `if not sel` (an empty-ish selection object for row 0 is falsy, which would make the first row unclickable); and `selection.data` is a **list** even in single-select mode, so index `[0]`.

- [ ] **Step 6: Repoint Search and Reset**

Update the root `search()` custom method to a one-liner delegating to the entity script — **not** `system.db.runNamedQuery`, which breaks the three-layer rule:

```python
	self.view.custom.results = BlueRidge.Lots.Lot.searchAdvanced(self.view.custom.filters)
```

`SearchButton.onActionPerformed` already calls `self.view.rootContainer.search()` — leave it.

Update `ResetButton.onActionPerformed`:

```python
	self.view.custom.filters = BlueRidge.Lots.Lot.emptyFilters()
	self.view.rootContainer.search()
```

`filters` is reseeded in **one** property write. Sequential per-key writes re-evaluate dependent bindings against a half-cleared object.

- [ ] **Step 7: Add CSV export**

Add an `ExportButton` to `ResultsHeader` with `onActionPerformed`:

```python
	BlueRidge.Lots.Lot.exportCsv(self.view.custom.results)
```

The handler reads `view.custom.results` rather than the table, which sidesteps addressing entirely — `getSibling` resolves only true siblings, and `ResultsTable` lives inside `ResultsPanel`.

- [ ] **Step 8: Scan and verify**

```bash
powershell -File scan.ps1
```

Open `/shop-floor/lot-search`: the page renders with no Component Error, the `Die Cast origin` group is visible, and the table shows Die / Cavity / Machine. Click a row — it must navigate, **including the first row**.

> The in-app browser renders views and fires buttons but **cannot commit input bindings** — dropdowns, date pickers and text fields will not take a value through it. Filter behaviour is already covered by Tasks 1–2 against the proc; use the browser for render and row-click only.

- [ ] **Step 9: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotSearch
git commit -m "feat(ui): LOT Search filters, Die/Cavity/Machine columns, CSV export and row-click drill-through"
```

---

## Task 8: Global Trace detail panels — **Designer**

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/GlobalTrace/view.json` — **in Designer**

**Interfaces:**
- Consumes: `BlueRidge.Lots.GlobalTrace.loadDetail(matchType, matchedEntityId, serialNumber)` from Task 6.
- Produces: nothing consumed later.

**Context:** the view already resolves identifiers through `BlueRidge.Lots.GlobalTrace.resolve` / `resolveForTable` and renders candidates via the `Trace/CandidateRow` repeater. Add panels — do not rebuild the resolver.

- [ ] **Step 1: Pre-declare both panel states**

Add to the view's `custom` block, fully shaped:

```json
"serialDetail": {
  "SerialNumber": null, "ItemId": null, "ItemPartNumber": null,
  "ProducingLotId": null, "ProducingLotName": null, "EtchedAt": null,
  "ProducedAt": null, "OperatorName": null, "MachineName": null,
  "ContainerId": null, "ContainerStatusCode": null, "AimShipperId": null,
  "CompletedAt": null
},
"containerDetail": {
  "ContainerId": null, "ItemId": null, "ItemPartNumber": null,
  "ContainerStatusCode": null, "PieceCount": 0, "SerialCount": 0,
  "SourceLotCount": 0, "OpenedAt": null, "CompletedAt": null,
  "AimShipperId": null, "OpenHoldCount": 0, "TotalHoldCount": 0
},
"containerSerials": [],
"containerHolds": [],
"activeMatchType": ""
```

`containerSerials` and `containerHolds` default to `[]` because bindings measure their length. Keys mirror `_EMPTY_TRACE_DETAIL` in the two entity modules exactly.

- [ ] **Step 2: Add the serial detail panel**

A flex container `SerialDetailPanel` with labelled fields bound to `view.custom.serialDetail.*`: Serial, Part, Producing LOT, Etched, Produced, Operator, Machine, Container, Container status, AIM Shipper ID, and **Completed**.

Bind visibility on **`position.display`** (removes it from layout), not `meta.visible` (which leaves it occupying flex space):

```
{view.custom.activeMatchType} = "Serial"
```

Expression language is C-style — `=` for equality, `&&` / `||` / `!` — not Python keywords, which evaluate as silently falsy. Expression string literals cannot carry `\u` escapes; embed any non-ASCII character literally or via `char(N)`.

**Label the `CompletedAt` field `Completed`.** Never "Ship date" — it is container-close time, the schema has no ship timestamp, and mislabelling it would misreport Honda traceability data.

- [ ] **Step 3: Add the container detail panel**

A flex container `ContainerDetailPanel`, `position.display` bound to:

```
{view.custom.activeMatchType} = "Container" || {view.custom.activeMatchType} = "Shipper"
```

Fields bound to `view.custom.containerDetail.*`: Container ID, Part, Status, Pieces, Serials, Source LOTs, Opened, **Completed**, AIM Shipper ID.

Plus two tables:
- `SerialListTable` bound to `view.custom.containerSerials` — Serial, Tray position, Producing LOT.
- `HoldHistoryTable` bound to `view.custom.containerHolds` — Hold type, Reason, Placed by, Placed at, Released by, Released at. **This table is the FDS-12-003 "hold history" element**; a count chip alone does not satisfy it.

Add a hold chip reading `OpenHoldCount` of `TotalHoldCount`, with `position.display` bound to `{view.custom.containerDetail.TotalHoldCount} > 0`.

Full ~25-key column schema on every column in both tables.

- [ ] **Step 4: Populate the panels on resolve**

In the handler that acts on a resolved candidate (the `CandidateRow` selection path), delegate and then write each block atomically:

```python
	d = BlueRidge.Lots.GlobalTrace.loadDetail(matchType, matchedEntityId, searchText)
	self.view.custom.serialDetail = d['serialDetail']
	self.view.custom.containerDetail = d['containerDetail']
	self.view.custom.containerSerials = d['containerSerials']
	self.view.custom.containerHolds = d['containerHolds']
	self.view.custom.activeMatchType = matchType
```

Each dict is assigned **whole**, in one property write per block. Sequential per-key writes re-evaluate dependent bindings against a half-populated object.

This body is six lines — past the 1–3 line inline cap — so factor it into a view `customMethod` on the **root** container (`root.scripts.customMethods`) and call it as a one-liner from the event. Addressing from a component event is `self.view.rootContainer.<method>()`.

The `CandidateRow` sub-view reaches the parent by **page-scoped** message (`scope='page'`, handler `pageScope: true`) — view scope does not propagate from an embedded view to its parent, and embed params are input-only so a bidirectional write inside the sub-view stays local.

- [ ] **Step 5: Scan and verify the empty state**

```bash
powershell -File scan.ps1
```

Open `/shop-floor/trace` with no input: both panels hidden, page renders with **no Component Error**. That is the check the shaped defaults in Step 1 exist to guarantee — a `None` from any binding source would replace the default and error on the first nested read.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/GlobalTrace
git commit -m "feat(ui): serial and container detail panels on Global Trace (FDS-12-002, FDS-12-003)"
```

---

## Done criteria

- `cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Search" -Filter ""` exits 0 with no failed assertions and no `ERROR running` lines.
- `077_Lot_Search.sql` passes **untouched**, the signature-parity test confirms `Lot_Search` still has exactly 4 parameters, and `BlueRidge.Lots.Lot.search(None, 1)` still works — the frozen path is intact end to end.
- `/shop-floor/lot-search` renders with all eleven filters, shows Die / Cavity / Machine, and a row click navigates — **including row 0**.
- `/shop-floor/trace` renders clean with no input; the serial panel shows for a scanned serial and the container panel for a container id or AIM shipper id.
- The `CompletedAt` field is labelled **`Completed`** on both panels.
- No migration was added; no view calls `system.db.*`; no inline handler exceeds three lines.

## Deliberately not built

- The literal **ship date** of FDS-12-002 / FDS-12-003 (spec §2.5). The panels show *whether* a container shipped via its status, not *when*. Closing it needs `Lots.Container.ShippedAt`.
- FDS-12-006 Rejects, FDS-12-010 Hold Status, FDS-12-011 Shipping History — the companion aggregate-reports spec, which also carries `RejectEvent.TerminalLocationId`, the `ChargeToParty` code table, and the Shipping History date-basis decision.
- The six documentation corrections in spec §10 — assigned to a separate agent.
