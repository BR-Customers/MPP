# LOT Search Extension + Serial / Container Trace Detail Panels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver FDS-12-002, FDS-12-003 and FDS-12-004 — rewrite `Lots.Lot_Search` with the full FDS-12-004 filter set and wire row-click navigation on the LOT Search screen, and add serial and container detail panels to the existing Global Trace surface.

**Architecture:** Three new/rewritten read procs, three named queries in the **Core** project, one existing Perspective view extended (LotSearch), one existing view gaining two panels (GlobalTrace). LOT Search stays a filtered browse; serial and container lookups become detail panels on Global Trace, dispatched off the `MatchType` that `Lots.GlobalTrace_Resolve` already returns. **No schema migration.**

**Tech Stack:** SQL Server 2022, Ignition 8.3 Perspective (file-based project resources), Jython 2.7 scripting, `sqlcmd`-driven test harness.

**Spec:** `docs/superpowers/specs/2026-08-24-lot-search-and-trace-detail-panels-design.md`

## Global Constraints

- **No `OUTPUT` parameters, ever** (FDS-11-011). Read procs return exactly one result set. Empty result set = not found; do not invent a 404.
- **One result set per proc.** If a panel needs a second collection, it calls a sibling proc.
- Naming: `UpperCamelCase` tables and columns; `BIGINT` for all ids; `NVARCHAR` never `VARCHAR`; `DATETIME2(3)` never `DATETIME`.
- **Timestamps are stored UTC and displayed Eastern.** Every operator-facing read converts at the boundary with `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- Schema-qualify every database reference (`Lots.Lot`, not `Lot`).
- `EXEC` parameters must be literals or `@variables` — never inline `CAST`, arithmetic, or `CASE`.
- Stored-proc template: `sql/scripts/_TEMPLATE_stored_procedure.sql`.
- **All named queries live in the `Core` project.** `MPP` and `MPP_Config` have zero local named queries.
- **No business logic in Python.** Domain rules go in SQL.
- Existing Perspective views are edited in **Designer**, not by file edit. New named queries and Python are file-edited, then `.\scan.ps1`.
- Commit to branch `jacques/working`. Stage explicit paths — never `git add -u` or `git add -A`. Omit any `Co-Authored-By` trailer.
- Seed/data string values are **ASCII-only**.

---

## File Structure

| File | Responsibility |
|---|---|
| `sql/migrations/repeatable/R__Lots_Lot_Search.sql` | **Rewrite.** 13-parameter filtered LOT browse (FDS-12-004). |
| `sql/migrations/repeatable/R__Lots_SerializedPart_GetTraceDetail.sql` | **New.** One-row serial trace payload (FDS-12-002). |
| `sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql` | **New.** One-row container trace payload (FDS-12-003). |
| `sql/migrations/repeatable/R__Lots_Container_ListSerials.sql` | **New.** Sibling read — the container's serial list. Separate proc because one proc returns one result set. |
| `sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql` | **New.** Sibling read — full hold history (open **and** released). The existing `Hold_GetOpenByContainer` filters to open holds and cannot serve FDS-12-003. |
| `sql/tests/0067_Lot_Search_Extended/010_filters.sql` | Per-filter coverage for the rewritten proc. |
| `sql/tests/0067_Lot_Search_Extended/020_date_boundary.sql` | Eastern-day boundary conversion. |
| `sql/tests/0067_Lot_Search_Extended/030_origin_conditional.sql` | NULL-Tool LOTs excluded by Die filter. |
| `sql/tests/0067_Lot_Search_Extended/040_total_count.sql` | `TotalCount` across a pager boundary. |
| `sql/tests/0068_Trace_Detail_Reads/010_serial_detail.sql` | `SerializedPart_GetTraceDetail`. |
| `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql` | `Container_GetTraceDetail` + `Container_ListSerials`. |
| `ignition/projects/Core/ignition/named-query/lots/Lot_Search/` | Parameters extended 4 → 13. |
| `ignition/projects/Core/ignition/named-query/lots/SerializedPart_GetTraceDetail/` | **New.** |
| `ignition/projects/Core/ignition/named-query/lots/Container_GetTraceDetail/` | **New.** |
| `ignition/projects/Core/ignition/named-query/lots/Container_ListSerials/` | **New.** |
| `ignition/projects/Core/ignition/named-query/quality/Hold_ListByContainer/` | **New.** Under `quality/`, matching its schema. |
| `.../views/BlueRidge/Views/ShopFloor/LotSearch/view.json` | 8 new filters, 3 new columns, row-click nav, CSV export, pickle cleanup. **Designer.** |
| `.../views/BlueRidge/Views/ShopFloor/GlobalTrace/view.json` | Serial + container detail panels. **Designer.** |

Task order is SQL first (Tasks 1–4), then Ignition (Tasks 5–7). SQL and named queries are serial work; the two view tasks are independent of each other.

---

## Task 1: Rewrite `Lots.Lot_Search`

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Search.sql` (full rewrite)
- Test: `sql/tests/0067_Lot_Search_Extended/010_filters.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Lots.Lot_Search` with parameters `@Query NVARCHAR(100)`, `@ItemId BIGINT`, `@CreatedFromEt DATE`, `@CreatedToEt DATE`, `@ToolId BIGINT`, `@ToolCavityId BIGINT`, `@LocationId BIGINT`, `@IncludeDescendants BIT`, `@MachineLocationId BIGINT`, `@ShiftId BIGINT`, `@LotStatusId BIGINT`, `@LotOriginTypeId BIGINT`, `@LimitRows INT` — all defaulting to `NULL` except `@IncludeDescendants BIT = 1` and `@LimitRows INT = 100`. Result set columns: `Id, LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, VendorLotNumber, CurrentLocationId, CreatedAt, ItemPartNumber, LotStatusCode, LotOriginTypeCode, CurrentLocationName, LastOperationName, ToolCode, CavityNumber, OriginMachineName, TotalCount`.

**Context the implementer needs:**

`Lots.Lot` carries `ToolId` and `ToolCavityId` (FK-backed) **and** legacy `DieNumber` / `CavityNumber` `NVARCHAR` columns that are no longer maintained. Filter and display the FK-backed pair only.

Origin machine comes from `Workorder.DieCastContribution.CellLocationId` — the press, stamped at write time by migration `0061`. Do **not** derive it from `Lots.LotMovement`; `0061` exists specifically to retire live re-derivation of the press, and movement-based derivation reintroduces the same drift.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0067_Lot_Search_Extended/010_filters.sql`:

```sql
-- =============================================
-- File:         0067_Lot_Search_Extended/010_filters.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-004 filter coverage for the rewritten Lots.Lot_Search.
--               One case per filter plus a combined case.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_Search_Extended/010_filters.sql';
GO

-- Result shape used by every INSERT-EXEC in this file.
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

SELECT TOP (1) @AnyItemId = ItemId, @AnyLocId = CurrentLocationId
FROM Lots.Lot ORDER BY Id;

-- 1. No filters returns rows.
INSERT INTO #LS EXEC Lots.Lot_Search;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsTrue @TestName = N'[Lot_Search] unfiltered returns at least one row',
    @Condition = @n;
DELETE FROM #LS;

-- 2. @ItemId narrows to that item only.
INSERT INTO #LS EXEC Lots.Lot_Search @ItemId = @AnyItemId;
SELECT @n = COUNT(*) FROM #LS WHERE ItemId <> @AnyItemId;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] @ItemId returns no foreign items',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 3. @LocationId with @IncludeDescendants = 0 is an exact-location match.
INSERT INTO #LS EXEC Lots.Lot_Search @LocationId = @AnyLocId, @IncludeDescendants = 0;
SELECT @n = COUNT(*) FROM #LS WHERE CurrentLocationId <> @AnyLocId;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] exact location filter admits no other location',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 4. @LocationId with descendants is a superset of the exact match.
DECLARE @Exact INT, @WithKids INT;
INSERT INTO #LS EXEC Lots.Lot_Search @LocationId = @AnyLocId, @IncludeDescendants = 0;
SELECT @Exact = COUNT(*) FROM #LS;
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_Search @LocationId = @AnyLocId, @IncludeDescendants = 1;
SELECT @WithKids = COUNT(*) FROM #LS;
DELETE FROM #LS;
SET @n = CASE WHEN @WithKids >= @Exact THEN 1 ELSE 0 END;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] descendant search is a superset of exact',
    @Expected = N'1', @Actual = @n;

-- 5. @LimitRows caps the row count.
INSERT INTO #LS EXEC Lots.Lot_Search @LimitRows = 1;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] @LimitRows = 1 returns exactly one row',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- 6. A nonsense free-text query returns nothing.
INSERT INTO #LS EXEC Lots.Lot_Search @Query = N'ZZZ-NO-SUCH-LOT-ZZZ';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] unmatched query returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 7. Combined filters do not error and stay within each constraint.
INSERT INTO #LS EXEC Lots.Lot_Search @ItemId = @AnyItemId, @LocationId = @AnyLocId,
                                     @IncludeDescendants = 1, @LimitRows = 50;
SELECT @n = COUNT(*) FROM #LS WHERE ItemId <> @AnyItemId;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] combined filters respect @ItemId',
    @Expected = N'0', @Actual = @n;

DROP TABLE #LS;
GO
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0067_Lot_Search_Extended
```

Expected: FAIL. The proc currently accepts only four parameters, so the `@ItemId` call errors with `Procedure or function Lot_Search has too many arguments specified`.

- [ ] **Step 3: Rewrite the proc**

Replace the body of `sql/migrations/repeatable/R__Lots_Lot_Search.sql`:

```sql
-- =============================================
-- Repeatable:  R__Lots_Lot_Search.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     2.0
-- Description: FDS-12-004 LOT Search. Filtered browse: free text, item, Eastern
--              created-day range, die, cavity, location (optionally including
--              descendants), origin machine, shift, status and origin type.
--              One result set (FDS-11-011); recency-ordered; TOP (@LimitRows)
--              with COUNT(*) OVER() AS TotalCount for the pager.
--
--              Die / Cavity / Machine / Shift are die-cast-origin dimensions.
--              Lot.ToolId and Lot.ToolCavityId are NULL on merged LOTs (OI-05)
--              and on non-cast origins, and origin machine resolves through
--              Workorder.DieCastContribution -- so any of those four filters
--              implicitly narrows to die-cast-origin LOTs. That is intended and
--              is surfaced in the UI, not compensated for here.
--
--              Origin machine is DieCastContribution.CellLocationId (the press,
--              stamped at write time by migration 0061). It is deliberately NOT
--              derived from LotMovement: 0061 exists to stop live re-derivation
--              of the press, and a movement-based derivation reintroduces the
--              same drift.
--
--              Dates are Eastern calendar days, inclusive on both bounds, and
--              are converted to a half-open UTC instant range inside the proc so
--              that the filter agrees with the Eastern-converted CreatedAt in
--              the SELECT.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Lot_Search
    @Query              NVARCHAR(100) = NULL,
    @ItemId             BIGINT        = NULL,
    @CreatedFromEt      DATE          = NULL,
    @CreatedToEt        DATE          = NULL,
    @ToolId             BIGINT        = NULL,
    @ToolCavityId       BIGINT        = NULL,
    @LocationId         BIGINT        = NULL,
    @IncludeDescendants BIT           = 1,
    @MachineLocationId  BIGINT        = NULL,
    @ShiftId            BIGINT        = NULL,
    @LotStatusId        BIGINT        = NULL,
    @LotOriginTypeId    BIGINT        = NULL,
    @LimitRows          INT           = 100
AS
BEGIN
    SET NOCOUNT ON;

    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;

    DECLARE @Q NVARCHAR(120) = CASE
        WHEN @Query IS NULL OR LTRIM(RTRIM(@Query)) = N'' THEN NULL
        ELSE N'%' + LTRIM(RTRIM(@Query)) + N'%' END;

    -- Eastern calendar days -> half-open UTC instant range.
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
      AND (@LocationId      IS NULL
           OR (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
           OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @LocationId))
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

- [ ] **Step 4: Apply the proc and run the test**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0067_Lot_Search_Extended
```

Expected: PASS, 7 assertions, exit 0.

> If the run reports `Test run FAILED` while showing 0 failed assertions, a `sqlcmd` error occurred — usually an FK violation during cleanup. That is a harness artifact, not a proc failure. Re-run unfiltered to confirm.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Search.sql sql/tests/0067_Lot_Search_Extended/010_filters.sql
git commit -m "feat(sql): rewrite Lot_Search with the full FDS-12-004 filter set"
```

---

## Task 2: `Lot_Search` date-boundary and origin-conditional tests

**Files:**
- Test: `sql/tests/0067_Lot_Search_Extended/020_date_boundary.sql`
- Test: `sql/tests/0067_Lot_Search_Extended/030_origin_conditional.sql`
- Test: `sql/tests/0067_Lot_Search_Extended/040_total_count.sql`

**Interfaces:**
- Consumes: `Lots.Lot_Search` from Task 1 (signature and result shape as declared there).
- Produces: nothing consumed by later tasks.

These are the three behaviours most likely to regress silently, so they get their own files and their own review gate.

- [ ] **Step 1: Write the date-boundary test**

Create `sql/tests/0067_Lot_Search_Extended/020_date_boundary.sql`:

```sql
-- =============================================
-- File:         0067_Lot_Search_Extended/020_date_boundary.sql
-- Author:       Blue Ridge Automation
-- Description:  The Eastern-day filter must agree with the Eastern-converted
--               CreatedAt column. A LOT created at 01:00 UTC on day D belongs to
--               Eastern day D-1 (21:00 EDT), and must be found by @CreatedToEt =
--               D-1 and NOT by @CreatedFromEt = D.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_Search_Extended/020_date_boundary.sql';
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

DECLARE @n INT, @LotId BIGINT, @LotName NVARCHAR(50);
DECLARE @ItemId BIGINT, @LocId BIGINT, @StatusId BIGINT, @OriginId BIGINT, @UserId BIGINT;

SELECT TOP (1) @ItemId = ItemId, @LocId = CurrentLocationId,
               @StatusId = LotStatusId, @OriginId = LotOriginTypeId,
               @UserId = CreatedByUserId
FROM Lots.Lot ORDER BY Id;

SET @LotName = N'TEST-TZ-BOUNDARY-01';

-- 2026-03-02 01:00 UTC == 2026-03-01 20:00 Eastern.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (@LotName, @ItemId, @OriginId, @StatusId, 1, @LocId, @UserId,
        CAST(N'2026-03-02T01:00:00' AS DATETIME2(3)));
SET @LotId = SCOPE_IDENTITY();

-- Found when searching the Eastern day it actually belongs to.
INSERT INTO #LS EXEC Lots.Lot_Search @Query = @LotName,
    @CreatedFromEt = '2026-03-01', @CreatedToEt = '2026-03-01';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] 01:00 UTC LOT is found on the prior Eastern day',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- Not found on the following Eastern day.
INSERT INTO #LS EXEC Lots.Lot_Search @Query = @LotName,
    @CreatedFromEt = '2026-03-02', @CreatedToEt = '2026-03-02';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] 01:00 UTC LOT is absent from the UTC day',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- @CreatedToEt is inclusive of its whole day.
INSERT INTO #LS EXEC Lots.Lot_Search @Query = @LotName,
    @CreatedFromEt = '2026-02-28', @CreatedToEt = '2026-03-01';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] @CreatedToEt is inclusive',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @LotId OR AncestorLotId = @LotId;
DELETE FROM Lots.Lot WHERE Id = @LotId;
DROP TABLE #LS;
GO
```

> **Teardown order matters.** `Lot_Create` writes a self-row into `Lots.LotGenealogyClosure`; deleting the LOT first raises `Msg 547`. This test inserts directly rather than through the proc, so the closure row may not exist — the `DELETE` is harmless either way and keeps the pattern correct if the test is later switched to `Lot_Create`.

- [ ] **Step 2: Write the origin-conditional test**

Create `sql/tests/0067_Lot_Search_Extended/030_origin_conditional.sql`:

```sql
-- =============================================
-- File:         0067_Lot_Search_Extended/030_origin_conditional.sql
-- Author:       Blue Ridge Automation
-- Description:  Die / Cavity are die-cast-origin dimensions. A LOT with NULL
--               ToolId (merged LOT per OI-05, or a non-cast origin) must appear
--               in an unfiltered search and disappear under any @ToolId filter.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_Search_Extended/030_origin_conditional.sql';
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

DECLARE @n INT, @LotId BIGINT, @LotName NVARCHAR(50), @AnyToolId BIGINT;
DECLARE @ItemId BIGINT, @LocId BIGINT, @StatusId BIGINT, @OriginId BIGINT, @UserId BIGINT;

SELECT TOP (1) @ItemId = ItemId, @LocId = CurrentLocationId,
               @StatusId = LotStatusId, @OriginId = LotOriginTypeId,
               @UserId = CreatedByUserId
FROM Lots.Lot ORDER BY Id;
SELECT TOP (1) @AnyToolId = Id FROM Tools.Tool ORDER BY Id;

SET @LotName = N'TEST-NULLTOOL-01';

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, ToolId, ToolCavityId)
VALUES (@LotName, @ItemId, @OriginId, @StatusId, 1, @LocId, @UserId, NULL, NULL);
SET @LotId = SCOPE_IDENTITY();

INSERT INTO #LS EXEC Lots.Lot_Search @Query = @LotName;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] NULL-Tool LOT is returned unfiltered',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

INSERT INTO #LS EXEC Lots.Lot_Search @Query = @LotName, @ToolId = @AnyToolId;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] NULL-Tool LOT is excluded by any @ToolId',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- ToolCode / CavityNumber render NULL rather than erroring on a NULL-Tool LOT.
INSERT INTO #LS EXEC Lots.Lot_Search @Query = @LotName;
SELECT @n = COUNT(*) FROM #LS WHERE ToolCode IS NOT NULL OR CavityNumber IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] NULL-Tool LOT yields NULL ToolCode and CavityNumber',
    @Expected = N'0', @Actual = @n;

DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @LotId OR AncestorLotId = @LotId;
DELETE FROM Lots.Lot WHERE Id = @LotId;
DROP TABLE #LS;
GO
```

- [ ] **Step 3: Write the TotalCount test**

Create `sql/tests/0067_Lot_Search_Extended/040_total_count.sql`:

```sql
-- =============================================
-- File:         0067_Lot_Search_Extended/040_total_count.sql
-- Author:       Blue Ridge Automation
-- Description:  COUNT(*) OVER() must report the FULL match count, not the
--               TOP-limited page size -- the pager depends on it.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0067_Lot_Search_Extended/040_total_count.sql';
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

INSERT INTO #LS EXEC Lots.Lot_Search @LimitRows = 1000;
SELECT @AllRows = COUNT(*) FROM #LS;
DELETE FROM #LS;

IF @AllRows < 2
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] TotalCount test skipped -- fewer than 2 LOTs seeded',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    INSERT INTO #LS EXEC Lots.Lot_Search @LimitRows = 1;
    SELECT @Rows = COUNT(*), @Total = MAX(TotalCount) FROM #LS;
    DELETE FROM #LS;

    EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] page returns exactly one row',
        @Expected = N'1', @Actual = @Rows;

    SET @n = CASE WHEN @Total = @AllRows THEN 1 ELSE 0 END;
    EXEC test.Assert_IsEqual @TestName = N'[Lot_Search] TotalCount reports full match count, not page size',
        @Expected = N'1', @Actual = @n;
END

DROP TABLE #LS;
GO
```

- [ ] **Step 4: Run all three and verify they pass**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0067_Lot_Search_Extended
```

Expected: PASS, all assertions across the four files, exit 0.

- [ ] **Step 5: Commit**

```bash
git add sql/tests/0067_Lot_Search_Extended/020_date_boundary.sql sql/tests/0067_Lot_Search_Extended/030_origin_conditional.sql sql/tests/0067_Lot_Search_Extended/040_total_count.sql
git commit -m "test(sql): Lot_Search Eastern-day boundary, origin-conditional and TotalCount coverage"
```

---

## Task 3: `Lots.SerializedPart_GetTraceDetail`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_SerializedPart_GetTraceDetail.sql`
- Test: `sql/tests/0068_Trace_Detail_Reads/010_serial_detail.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Lots.SerializedPart_GetTraceDetail @SerialNumber NVARCHAR(50)`. Result set: `SerialNumber, ItemId, ItemPartNumber, ProducingLotId, ProducingLotName, EtchedAt, ProducedAt, OperatorName, MachineName, ContainerId, ContainerStatusCode, AimShipperId, CompletedAt`. Zero rows when the serial does not exist.

**Context the implementer needs:**

`Lots.SerializedPart` is `Id, SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId` with `UQ_SerializedPart_SerialNumber`. The link to a container is `Lots.ContainerSerial` (`ContainerId`, `ContainerTrayId`, `SerializedPartId`, `TrayPosition`), and the Honda identifier is `Lots.ShippingLabel.AimShipperId`.

**There is no ship-date column in the schema** (spec §2.5). Return `Container.CompletedAt` as `CompletedAt`. Do **not** alias it to anything containing the word "ship" — the view labels it *Completed*, and mislabelling container-close time as ship time would misreport Honda traceability data.

A container may carry more than one non-void shipping label over its life (reprints, voids). Take the most recent non-void one.

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

-- Unknown serial returns an empty set (FDS-11-011: no invented 404).
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
    EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] producing LOT and part number are populated',
        @Expected = N'0', @Actual = @n;
END

DROP TABLE #SD;
GO
```

- [ ] **Step 2: Run and verify it fails**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0068_Trace_Detail_Reads
```

Expected: FAIL with `Could not find stored procedure 'Lots.SerializedPart_GetTraceDetail'`.

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
--              time. The schema has no ship timestamp (design spec 2.5); the
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

> `Location.AppUser.DisplayName NVARCHAR(200) NOT NULL` is the operator's display name — verified present, no lookup needed.

- [ ] **Step 4: Run and verify it passes**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0068_Trace_Detail_Reads
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
- Test: `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Lots.Container_GetTraceDetail @ContainerId BIGINT`. Result set: `ContainerId, ItemId, ItemPartNumber, ContainerStatusCode, PieceCount, SerialCount, SourceLotCount, OpenedAt, CompletedAt, AimShipperId, OpenHoldCount, TotalHoldCount`.
  - `Lots.Container_ListSerials @ContainerId BIGINT`. Result set: `SerializedPartId, SerialNumber, TrayPosition, ProducingLotId, ProducingLotName`.

**Context the implementer needs:**

Piece count derives from `Lots.ContainerTray.PartsClosedCount` summed across the container's trays. Serial count is the `Lots.ContainerSerial` row count. Source LOTs come from two places, matching how `GlobalTrace_Resolve` expands a container: `ContainerTray.FinishedGoodLotId` (added by migration `0034`) UNIONed with `ContainerSerial -> SerializedPart.ProducingLotId`.

Hold history is `Quality.HoldEvent` filtered on `ContainerId`. That table has a `CK_HoldEvent_LotXorContainer` check — a row carries **either** `LotId` or `ContainerId`, never both. An open hold is `ReleasedAt IS NULL`.

Two procs, not one, because a proc returns exactly one result set. The panel calls both.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql`:

```sql
-- =============================================
-- File:         0068_Trace_Detail_Reads/020_container_detail.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-003 container trace payload + its serial-list sibling.
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

DECLARE @n INT, @ContainerId BIGINT;

-- Unknown container returns an empty set.
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

SELECT TOP (1) @ContainerId = Id FROM Lots.Container ORDER BY Id;

IF @ContainerId IS NULL
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] known-container test skipped -- no Container seeded',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    INSERT INTO #CD EXEC Lots.Container_GetTraceDetail @ContainerId = @ContainerId;
    SELECT @n = COUNT(*) FROM #CD;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] known container returns exactly one row',
        @Expected = N'1', @Actual = @n;

    SELECT @n = COUNT(*) FROM #CD WHERE ItemPartNumber IS NULL OR ContainerStatusCode IS NULL;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] part number and status are populated',
        @Expected = N'0', @Actual = @n;

    SELECT @n = COUNT(*) FROM #CD WHERE PieceCount IS NULL OR SerialCount IS NULL OR SourceLotCount IS NULL;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] derived counts are never NULL',
        @Expected = N'0', @Actual = @n;

    -- SerialCount agrees with the sibling list proc.
    DECLARE @Declared INT, @Listed INT;
    SELECT @Declared = MAX(SerialCount) FROM #CD;
    INSERT INTO #CS EXEC Lots.Container_ListSerials @ContainerId = @ContainerId;
    SELECT @Listed = COUNT(*) FROM #CS;
    SET @n = CASE WHEN @Declared = @Listed THEN 1 ELSE 0 END;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] SerialCount matches Container_ListSerials row count',
        @Expected = N'1', @Actual = @n;
END

DROP TABLE #CD;
DROP TABLE #CS;
GO
```

- [ ] **Step 2: Run and verify it fails**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0068_Trace_Detail_Reads
```

Expected: FAIL with `Could not find stored procedure 'Lots.Container_GetTraceDetail'`.

- [ ] **Step 3: Write `Container_GetTraceDetail`**

Create `sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql`:

```sql
-- =============================================
-- Repeatable:  R__Lots_Container_GetTraceDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-003 Container Search payload, rendered as a detail panel
--              on Global Trace. One result set (FDS-11-011); empty set means the
--              container is unknown. The serial list is the sibling proc
--              Lots.Container_ListSerials -- one proc, one result set.
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
        ISNULL(tray.PieceCount, 0)  AS PieceCount,
        ISNULL(ser.SerialCount, 0)  AS SerialCount,
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

FDS-12-003 asks for hold **history**, not just open holds. The existing `Quality.Hold_GetOpenByContainer` filters `ReleasedAt IS NULL`, so it cannot serve this. Create `sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql`:

```sql
-- =============================================
-- Repeatable:  R__Quality_Hold_ListByContainer.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-003 hold HISTORY for a container -- open and released,
--              newest first. Distinct from Quality.Hold_GetOpenByContainer,
--              which filters to ReleasedAt IS NULL and therefore cannot show
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
    INNER JOIN Quality.HoldTypeCode htc  ON htc.Id    = he.HoldTypeCodeId
    INNER JOIN Location.AppUser     placed ON placed.Id = he.PlacedByUserId
    LEFT  JOIN Location.AppUser     rel    ON rel.Id    = he.ReleasedByUserId
    WHERE he.ContainerId = @ContainerId
    ORDER BY he.PlacedAt DESC, he.Id DESC;
END
GO
```

Add to `sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql`, before the `DROP TABLE` statements:

```sql
CREATE TABLE #CH (
    HoldEventId BIGINT, HoldTypeCode NVARCHAR(50), HoldTypeName NVARCHAR(100),
    Reason NVARCHAR(500), PlacedByName NVARCHAR(200), PlacedAt DATETIME2(3),
    ReleasedByName NVARCHAR(200), ReleasedAt DATETIME2(3),
    ReleaseRemarks NVARCHAR(500), IsOpen INT
);

INSERT INTO #CH EXEC Quality.Hold_ListByContainer @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CH;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CH;

-- History count must agree with the detail proc's TotalHoldCount.
IF @ContainerId IS NOT NULL
BEGIN
    DECLARE @DeclaredHolds INT, @ListedHolds INT;
    SELECT @DeclaredHolds = MAX(TotalHoldCount) FROM #CD;
    INSERT INTO #CH EXEC Quality.Hold_ListByContainer @ContainerId = @ContainerId;
    SELECT @ListedHolds = COUNT(*) FROM #CH;
    SET @n = CASE WHEN @DeclaredHolds = @ListedHolds THEN 1 ELSE 0 END;
    EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] TotalHoldCount matches Hold_ListByContainer row count',
        @Expected = N'1', @Actual = @n;
END

DROP TABLE #CH;
```

> The `#CD` temp table must still be in scope, so insert this block **before** `DROP TABLE #CD;`.

- [ ] **Step 6: Run and verify it passes**

```bash
powershell -File sql/scripts/Run-Tests.ps1 -Filter 0068_Trace_Detail_Reads
```

Expected: PASS.

- [ ] **Step 7: Run the full suite for regressions**

```bash
powershell -File sql/scripts/Run-Tests.ps1
```

Expected: exit 0, no failed assertions. `Lot_Search` had existing callers, so a full run is required here rather than optional.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_GetTraceDetail.sql sql/migrations/repeatable/R__Lots_Container_ListSerials.sql sql/migrations/repeatable/R__Quality_Hold_ListByContainer.sql sql/tests/0068_Trace_Detail_Reads/020_container_detail.sql
git commit -m "feat(sql): container trace detail, serial list and hold history for FDS-12-003"
```

---

## Task 5: Named queries

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Search/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Search/resource.json`
- Create: `ignition/projects/Core/ignition/named-query/lots/SerializedPart_GetTraceDetail/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/lots/Container_GetTraceDetail/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/lots/Container_ListSerials/{query.sql,resource.json}`

**Interfaces:**
- Consumes: the four procs from Tasks 1, 3, 4.
- Produces: named queries `lots/Lot_Search`, `lots/SerializedPart_GetTraceDetail`, `lots/Container_GetTraceDetail`, `lots/Container_ListSerials`, callable from views via `system.db.runNamedQuery`.

**Context the implementer needs:**

`sqlType` codes used in this project: `2` = Integer, `3` = Long, `7` = String, `8` = DateTime, `20` = binary/rowversion. Date parameters use **`8`**.

These are **read** procs returning a plain result set, so `attributes.type` is `"Query"`. (`"Query"` is also correct for mutation procs that end with `SELECT @Status...`; the mistyping that breaks things is using `"Query"` on a *silent* proc that returns no result set.)

Named queries live in **Core** only.

- [ ] **Step 1: Extend the `Lot_Search` query**

Replace `ignition/projects/Core/ignition/named-query/lots/Lot_Search/query.sql`:

```sql
EXEC Lots.Lot_Search
    @Query              = :query,
    @ItemId             = :itemId,
    @CreatedFromEt      = :createdFromEt,
    @CreatedToEt        = :createdToEt,
    @ToolId             = :toolId,
    @ToolCavityId       = :toolCavityId,
    @LocationId         = :locationId,
    @IncludeDescendants = :includeDescendants,
    @MachineLocationId  = :machineLocationId,
    @ShiftId            = :shiftId,
    @LotStatusId        = :lotStatusId,
    @LotOriginTypeId    = :lotOriginTypeId,
    @LimitRows          = :limitRows
```

- [ ] **Step 2: Extend the `Lot_Search` parameter list**

In `ignition/projects/Core/ignition/named-query/lots/Lot_Search/resource.json`, replace the `attributes.parameters` array with:

```json
    "parameters": [
      { "type": "Parameter", "identifier": "query",              "sqlType": 7 },
      { "type": "Parameter", "identifier": "itemId",             "sqlType": 3 },
      { "type": "Parameter", "identifier": "createdFromEt",      "sqlType": 8 },
      { "type": "Parameter", "identifier": "createdToEt",        "sqlType": 8 },
      { "type": "Parameter", "identifier": "toolId",             "sqlType": 3 },
      { "type": "Parameter", "identifier": "toolCavityId",       "sqlType": 3 },
      { "type": "Parameter", "identifier": "locationId",         "sqlType": 3 },
      { "type": "Parameter", "identifier": "includeDescendants", "sqlType": 2 },
      { "type": "Parameter", "identifier": "machineLocationId",  "sqlType": 3 },
      { "type": "Parameter", "identifier": "shiftId",            "sqlType": 3 },
      { "type": "Parameter", "identifier": "lotStatusId",        "sqlType": 3 },
      { "type": "Parameter", "identifier": "lotOriginTypeId",    "sqlType": 3 },
      { "type": "Parameter", "identifier": "limitRows",          "sqlType": 2 }
    ]
```

Leave every other key in the file untouched.

- [ ] **Step 3: Create the three new named queries**

`.../lots/SerializedPart_GetTraceDetail/query.sql`:

```sql
EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = :serialNumber
```

`.../lots/SerializedPart_GetTraceDetail/resource.json`:

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
      { "type": "Parameter", "identifier": "serialNumber", "sqlType": 7 }
    ]
  }
}
```

`.../lots/Container_GetTraceDetail/query.sql`:

```sql
EXEC Lots.Container_GetTraceDetail @ContainerId = :containerId
```

`.../lots/Container_GetTraceDetail/resource.json` — identical to the file above except the `parameters` array:

```json
    "parameters": [
      { "type": "Parameter", "identifier": "containerId", "sqlType": 3 }
    ]
```

`.../lots/Container_ListSerials/query.sql`:

```sql
EXEC Lots.Container_ListSerials @ContainerId = :containerId
```

`.../lots/Container_ListSerials/resource.json` — identical, same `parameters` array as `Container_GetTraceDetail`.

`ignition/projects/Core/ignition/named-query/quality/Hold_ListByContainer/query.sql`:

```sql
EXEC Quality.Hold_ListByContainer @ContainerId = :containerId
```

`.../quality/Hold_ListByContainer/resource.json` — same file body, same `parameters` array as `Container_GetTraceDetail`. Note this one lives under `quality/`, not `lots/`, matching its schema and the existing `quality/Hold_*` queries.

- [ ] **Step 4: Scan the gateway**

```bash
powershell -File scan.ps1
```

Expected: completes without error and reports the changed resources. If it returns 403, the POST is missing one of the two required headers (`X-Ignition-API-Token` **and** `Content-Type: application/json`).

- [ ] **Step 5: Verify each named query resolves**

In the Designer script console, or a Perspective script:

```python
from java.util import Date
print system.db.runNamedQuery("lots/Container_ListSerials", {"containerId": -1}).getRowCount()
```

Expected: `0` — the query resolves and returns an empty dataset. An exception naming the query means the resource did not deploy; check `wrapper.log` for `Named query not found`.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_Search ignition/projects/Core/ignition/named-query/lots/SerializedPart_GetTraceDetail ignition/projects/Core/ignition/named-query/lots/Container_GetTraceDetail ignition/projects/Core/ignition/named-query/lots/Container_ListSerials ignition/projects/Core/ignition/named-query/quality/Hold_ListByContainer
git commit -m "feat(ignition): named queries for extended Lot_Search and the trace detail reads"
```

---

## Task 6: Extend the LOT Search view

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotSearch/view.json` — **in Designer**

**Interfaces:**
- Consumes: named query `lots/Lot_Search` from Task 5, with the 13 parameters named there.
- Produces: nothing consumed by later tasks.

**Context the implementer needs:**

This view already exists with `QueryInput`, `StatusDropdown`, `OriginDropdown`, `SearchButton`, `ResetButton` and a `ResultsTable`, laid out under a `SearchBar` flex container. Extend it — do not rebuild it.

**Edit this view in Designer, not by file edit.** Designer's GSON serialization writes `=`, `'`, `<` and `>` as six-character unicode escapes, and its in-memory model conflicts with on-disk changes.

- [ ] **Step 1: Reset the pickled result data**

`custom.results` currently holds 33 live rows from the Dev database, saved as the property default. Set it to `[]`.

Then confirm the cleanup landed and nothing else did:

```bash
git diff --stat ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotSearch/view.json
```

Expected: a diff that *removes* lines. A large diff for a small change means Designer re-pickled live data — investigate before continuing.

- [ ] **Step 2: Add the eight filter controls**

In `SearchBar`, add these alongside the existing Query / Status / Origin controls. Each follows the existing `<Name>Field` flex-container pattern (label + input):

| Control | Component | Binds to |
|---|---|---|
| `PartField` | `ia.input.dropdown` | `view.custom.filters.itemId` |
| `CreatedFromField` | `ia.input.date-time-input` | `view.custom.filters.createdFromEt` |
| `CreatedToField` | `ia.input.date-time-input` | `view.custom.filters.createdToEt` |
| `DieField` | `ia.input.dropdown` | `view.custom.filters.toolId` |
| `CavityField` | `ia.input.dropdown` | `view.custom.filters.toolCavityId` |
| `LocationField` | `ia.input.dropdown` | `view.custom.filters.locationId` |
| `MachineField` | `ia.input.dropdown` | `view.custom.filters.machineLocationId` |
| `ShiftField` | `ia.input.dropdown` | `view.custom.filters.shiftId` |

Group `DieField`, `CavityField`, `MachineField` and `ShiftField` inside a flex container named `DieCastOriginGroup` with a label reading `Die Cast origin` — these four filters implicitly narrow results to die-cast-origin LOTs, and the grouping is what tells the operator why.

Dropdown `options` must be `{label, value}` objects only — a `code` or `name` key breaks the component. A placeholder is an **object** (`{text, color, icon}`), not a string.

- [ ] **Step 3: Pre-declare the filter state**

Add to the view's `custom` block, with every key present:

```json
"filters": {
  "itemId": null,
  "createdFromEt": null,
  "createdToEt": null,
  "toolId": null,
  "toolCavityId": null,
  "locationId": null,
  "includeDescendants": 1,
  "machineLocationId": null,
  "shiftId": null
}
```

Every `view.custom.*` property a binding reads needs a fully-shaped default. A binding that traverses a nested path against a property that does not yet exist renders the component as a Component Error.

- [ ] **Step 4: Add the three result columns**

Add `ToolCode` (header `Die`), `CavityNumber` (header `Cavity`) and `OriginMachineName` (header `Machine`) to `ResultsTable.props.columns`.

Each column entry needs the **full ~25-key column schema**. An abbreviated entry produces a Component Error after the next scan. Copy an existing column object from the same array and change `field`, `header` and width.

- [ ] **Step 5: Wire row-click navigation**

On `ResultsTable`, add an **`onSelectionChange`** event script. `onRowClick` does not fire on `ia.display.table` and fails silently:

```python
	sel = self.props.selection.data
	if sel is None:
		return
	if len(sel) == 0:
		return
	row = sel[0]
	lotId = row['Id']
	if lotId is None:
		return
	system.perspective.navigate(page='/shop-floor/lot-detail/%d' % int(lotId))
```

Two things to get right. The body starts with a **tab** — Designer wraps it in `def runAction(self, event):`, so a column-0 body is an `IndentationError`. And the guard is `if sel is None`, never `if not sel` — an empty-ish selection object for row 0 is falsy and would make the first row unclickable.

- [ ] **Step 6: Wire the Search button to the extended query**

Update the `SearchButton` `onActionPerformed` script to pass all thirteen parameters:

```python
	f = self.view.custom.filters
	params = {
		'query':              self.view.custom.query,
		'itemId':             f.itemId,
		'createdFromEt':      f.createdFromEt,
		'createdToEt':        f.createdToEt,
		'toolId':             f.toolId,
		'toolCavityId':       f.toolCavityId,
		'locationId':         f.locationId,
		'includeDescendants': f.includeDescendants,
		'machineLocationId':  f.machineLocationId,
		'shiftId':            f.shiftId,
		'lotStatusId':        self.view.custom.statusId,
		'lotOriginTypeId':    self.view.custom.originId,
		'limitRows':          100
	}
	ds = system.db.runNamedQuery('lots/Lot_Search', params)
	self.view.custom.results = system.dataset.toPyDataSet(ds)
```

Set `deferUpdates: false` on `QueryInput`. A text field commits its bound value on blur; a button that reads it before the commit lands gets an empty string and silently searches for nothing.

- [ ] **Step 7: Extend Reset**

Update `ResetButton` `onActionPerformed` to clear `view.custom.filters` back to the Step 3 shape **as a single property write**, not nine sequential ones, and to clear `view.custom.results` to `[]`.

- [ ] **Step 8: Add CSV export**

Add an `ExportButton` to `ResultsHeader` with `onActionPerformed`:

```python
	rows = self.view.custom.results
	if rows is None or len(rows) == 0:
		system.perspective.sendMessage('mpp-toast', {
			'title': 'Nothing to export',
			'message': 'Run a search first.',
			'level': 'info'
		}, scope='session')
		return
	csv = system.dataset.toCSV(system.dataset.toDataSet(rows))
	system.perspective.download('lot-search.csv', csv)
```

- [ ] **Step 9: Scan and verify in the browser**

```bash
powershell -File scan.ps1
```

Then open `/shop-floor/lot-search` and confirm: the page renders with no Component Error, the `Die Cast origin` group is visible, and the results table shows the three new columns.

> The in-app browser renders Perspective views and fires buttons but **cannot commit input bindings** — dropdowns, date pickers and text fields will not take a value through it. Verify filter behaviour by calling the proc directly in SQL (Tasks 1–2 already cover it); verify row-click and the rendered layout in the browser or Designer.

- [ ] **Step 10: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotSearch
git commit -m "feat(ui): extend LOT Search with FDS-12-004 filters, Die/Cavity/Machine columns and row-click drill-through"
```

---

## Task 7: Global Trace serial and container detail panels

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/GlobalTrace/view.json` — **in Designer**

**Interfaces:**
- Consumes: named queries `lots/SerializedPart_GetTraceDetail`, `lots/Container_GetTraceDetail`, `lots/Container_ListSerials` from Task 5.
- Produces: nothing consumed by later tasks.

**Context the implementer needs:**

`Lots.GlobalTrace_Resolve` already returns a `MatchType` column valued `'Lot'`, `'Serial'`, `'Container'` or `'Shipper'`, plus `MatchedEntityId`. The panels dispatch off that — no new resolver, no new search box.

For a `'Shipper'` match, `MatchedEntityId` is the shipping-label row; the container panel is still the right destination, reached via that label's `ContainerId`.

**Edit in Designer, not by file edit.**

- [ ] **Step 1: Pre-declare both panel states**

Add to the view's `custom` block, fully shaped:

```json
"serialDetail": {
  "SerialNumber": null,
  "ItemPartNumber": null,
  "ProducingLotId": null,
  "ProducingLotName": null,
  "EtchedAt": null,
  "ProducedAt": null,
  "OperatorName": null,
  "MachineName": null,
  "ContainerId": null,
  "ContainerStatusCode": null,
  "AimShipperId": null,
  "CompletedAt": null
},
"containerDetail": {
  "ContainerId": null,
  "ItemPartNumber": null,
  "ContainerStatusCode": null,
  "PieceCount": 0,
  "SerialCount": 0,
  "SourceLotCount": 0,
  "OpenedAt": null,
  "CompletedAt": null,
  "AimShipperId": null,
  "OpenHoldCount": 0,
  "TotalHoldCount": 0
},
"containerSerials": [],
"containerHolds": []
```

Every key the panels bind must exist here. `containerSerials` and `containerHolds` default to `[]` because bindings measure their length.

- [ ] **Step 2: Add the serial detail panel**

A flex container `SerialDetailPanel`, visible when the resolved `MatchType` is `'Serial'`, with labelled fields bound to `view.custom.serialDetail.*`.

Label the `CompletedAt` field **`Completed`**. Do **not** label it "Ship date" — it is container-close time, and the schema has no ship timestamp. Mislabelling it would misreport Honda traceability data.

- [ ] **Step 3: Add the container detail panel**

A flex container `ContainerDetailPanel`, visible when `MatchType` is `'Container'` or `'Shipper'`, with fields bound to `view.custom.containerDetail.*` plus a table bound to `view.custom.containerSerials`.

Same labelling rule: `CompletedAt` is **`Completed`**.

Surface holds as a chip reading `OpenHoldCount` open of `TotalHoldCount`, hidden when `TotalHoldCount` is `0`, plus a `HoldHistoryTable` bound to `view.custom.containerHolds` showing hold type, reason, placed-by, placed-at, released-by and released-at. That table is the FDS-12-003 *hold history* element — the count chip alone does not satisfy it.

- [ ] **Step 4: Populate the panels on resolve**

In the view method that handles a resolver result, dispatch on `MatchType`:

```python
	def loadDetail(self, matchType, matchedEntityId, serialNumber):
		if matchType == 'Serial':
			ds = system.db.runNamedQuery('lots/SerializedPart_GetTraceDetail',
				{'serialNumber': serialNumber})
			rows = system.dataset.toPyDataSet(ds)
			if len(rows) == 0:
				return
			r = rows[0]
			self.view.custom.serialDetail = {
				'SerialNumber':        r['SerialNumber'],
				'ItemPartNumber':      r['ItemPartNumber'],
				'ProducingLotId':      r['ProducingLotId'],
				'ProducingLotName':    r['ProducingLotName'],
				'EtchedAt':            r['EtchedAt'],
				'ProducedAt':          r['ProducedAt'],
				'OperatorName':        r['OperatorName'],
				'MachineName':         r['MachineName'],
				'ContainerId':         r['ContainerId'],
				'ContainerStatusCode': r['ContainerStatusCode'],
				'AimShipperId':        r['AimShipperId'],
				'CompletedAt':         r['CompletedAt']
			}
		elif matchType == 'Container':
			self.loadContainer(matchedEntityId)
```

Write the whole dictionary in **one** property assignment. Sequential per-key writes re-evaluate dependent bindings against a half-populated object.

- [ ] **Step 5: Add the container loader**

```python
	def loadContainer(self, containerId):
		ds = system.db.runNamedQuery('lots/Container_GetTraceDetail',
			{'containerId': containerId})
		rows = system.dataset.toPyDataSet(ds)
		if len(rows) == 0:
			return
		r = rows[0]
		self.view.custom.containerDetail = {
			'ContainerId':         r['ContainerId'],
			'ItemPartNumber':      r['ItemPartNumber'],
			'ContainerStatusCode': r['ContainerStatusCode'],
			'PieceCount':          r['PieceCount'],
			'SerialCount':         r['SerialCount'],
			'SourceLotCount':      r['SourceLotCount'],
			'OpenedAt':            r['OpenedAt'],
			'CompletedAt':         r['CompletedAt'],
			'AimShipperId':        r['AimShipperId'],
			'OpenHoldCount':       r['OpenHoldCount'],
			'TotalHoldCount':      r['TotalHoldCount']
		}
		sds = system.db.runNamedQuery('lots/Container_ListSerials',
			{'containerId': containerId})
		self.view.custom.containerSerials = system.dataset.toPyDataSet(sds)
		hds = system.db.runNamedQuery('quality/Hold_ListByContainer',
			{'containerId': containerId})
		self.view.custom.containerHolds = system.dataset.toPyDataSet(hds)
```

- [ ] **Step 6: Scan and verify**

```bash
powershell -File scan.ps1
```

Open `/shop-floor/trace`. With no input, both panels must be hidden and the page must render with **no Component Error** — that is the empty-state check, and it is what the pre-declared defaults in Step 1 exist to guarantee.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/GlobalTrace
git commit -m "feat(ui): serial and container detail panels on Global Trace (FDS-12-002, FDS-12-003)"
```

---

## Done criteria

- `powershell -File sql/scripts/Run-Tests.ps1` exits 0 with no failed assertions.
- `/shop-floor/lot-search` renders with all eleven filters, shows Die / Cavity / Machine columns, and a row click lands on that LOT's detail page — **including row 0**.
- `/shop-floor/trace` renders clean with no input, shows the serial panel for a scanned serial and the container panel for a container id or AIM shipper id.
- The `Completed` field is labelled `Completed` on both panels.
- No migration was added.

## Deliberately not built

- The literal **ship date** of FDS-12-002 / FDS-12-003 (spec §2.5). The panels show *whether* a container shipped via its status, not *when*. Closing this needs `Lots.Container.ShippedAt`.
- FDS-12-006 Rejects, FDS-12-010 Hold Status, FDS-12-011 Shipping History — the companion aggregate-reports spec, which also carries `RejectEvent.TerminalLocationId`, the `ChargeToParty` code table, and the Shipping History date-basis decision.
- The six documentation corrections in spec §10 — assigned to a separate agent.
