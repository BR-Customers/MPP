# LOT Genealogy & Traceability Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing Lot Detail report into a full LOT genealogy & traceability report — correct per-edge consumed quantities, both-direction genealogy to full depth, a descendant-aware shipped-container band with Honda AIM IDs, and a per-event lifecycle timeline.

**Architecture:** Three new SQL read procs (recursive edge-walk genealogy, LotEventLog lifecycle, descendant-aware shipped containers) supply four report bands. All new logic lives in SQL (read procs, FDS-11-011 conventions); the report's data sources `EXEC` those procs directly (report data sources are embedded SQL, not Named Queries). No schema changes.

**Tech Stack:** SQL Server 2022 (T-SQL repeatable migrations + `test.*` harness run via `sql/tests/Run-Tests.ps1`), Ignition 8.3 Reporting Module (`data.bin` report resource edited via the `ignition-reporting` skill), deployed with `scan.ps1`.

**Spec:** `docs/superpowers/specs/2026-08-11-lot-genealogy-traceability-report-design.md`

## Global Constraints

Every task's requirements implicitly include these (verbatim from CLAUDE.md / spec):

- **Read-proc convention (FDS-11-011):** No `OUTPUT` params. No `@Status`/`@Message`/status row. Exactly ONE result set. Empty result set = not found (no invented 404 row).
- **Timestamps:** Stored UTC, displayed Eastern. Every displayed timestamp converts at the read boundary via `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`. Order on raw UTC; project the ET cast.
- **SQL naming:** `UpperCamelCase` tables/columns; `NVARCHAR` (never `VARCHAR`); `DATETIME2(3)`; `BIGINT` ids/FKs.
- **ASCII-only** string literals in SQL (no em-dash / middle-dot / arrows beyond `->` `<-`) — `sqlcmd` codepage mojibakes non-ASCII.
- **Report data sources** are flat embedded PrepStmt SQL that `EXEC`s a read proc with `?` bound positionally — NOT Named Queries. (`ignition-context-pack/10_reporting_module.md` §"Data sources".)
- **Report edits** go through the `ignition-reporting` skill (edit `data.bin` via its Python codec); after any Ignition resource change run `.\scan.ps1`; render-verify against the running gateway.
- **Git:** branch `jacques/working` (confirm first). Stage explicit paths only — never `git add -u`/`-A`. Omit the `Co-Authored-By: Claude` trailer.
- **Test DB:** `Run-Tests.ps1` resets the throwaway `MPP_MES_Test` (never `MPP_MES_Dev`). Run a single suite with `-Filter`.

**Repeatable-migration + test dev loop (used by every SQL task):**
```bash
# from repo root, PowerShell:
./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"
```
This resets `MPP_MES_Test`, applies all versioned + `R__` repeatable migrations (so a new/edited `R__` proc is picked up automatically), then runs the matching test files. A red run prints the failing `sqlcmd` output.

---

### Task 1: `Lots.Lot_GetGenealogyEdgeTree` read proc

Recursive walk over the `Lots.LotGenealogy` **edge** table (not the closure) returning the full ancestor and/or descendant tree with per-edge consumed `PieceCount`, depth, and the related part's preferred UOM.

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetGenealogyEdgeTree.sql`
- Test: `sql/tests/0055_LotGenealogyReport/010_Lot_GetGenealogyEdgeTree.sql`

**Interfaces:**
- Consumes: `Lots.LotGenealogy(ParentLotId, ChildLotId, RelationshipTypeId, PieceCount)`, `Lots.Lot(Id, LotName, ItemId)`, `Parts.Item(Id, PartNumber, UomId)`, `Parts.Uom(Id, Code)`, `Lots.GenealogyRelationshipType(Id, Name)`. Fixtures call `Lots.Lot_Create` and `Lots.LotGenealogy_RecordConsumption`.
- Produces: `Lots.Lot_GetGenealogyEdgeTree(@LotId BIGINT, @Direction NVARCHAR(20) = N'Both')` → result columns `RelatedLotId BIGINT, RelatedLotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), RelationshipName NVARCHAR(100), PieceCount INT, UomCode NVARCHAR(20), Depth INT, Direction NVARCHAR(20)`. `@Direction` ∈ Ancestors/Descendants/Both (case-insensitive, singular/plural, unknown→Both).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0055_LotGenealogyReport/010_Lot_GetGenealogyEdgeTree.sql`:

```sql
-- =============================================
-- 0055_LotGenealogyReport/010_Lot_GetGenealogyEdgeTree.sql
-- Recursive edge-walk genealogy for the traceability report. READ proc.
-- Builds a 2-level consumption chain with KNOWN per-edge consumed counts
-- (A --96--> B --50--> C) and asserts the proc surfaces the CONSUMED count
-- (96), not the source LOT's own quantity (1000), at the right depth/direction.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0055_LotGenealogyReport/010_Lot_GetGenealogyEdgeTree.sql';
GO

IF OBJECT_ID(N'tempdb..#Fix') IS NOT NULL DROP TABLE #Fix;
CREATE TABLE #Fix (Tag NVARCHAR(10) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
GO

-- Eligible (Item, Cell) with no active tool assignment and uncapped basket size.
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- A: source, 1000 pcs (only 96 of it will be consumed into B).
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=1000, @AppUserId=1;
INSERT INTO #Fix SELECT N'A', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
-- B: produced from A, 200 pcs (50 of it consumed into C).
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=200, @AppUserId=1;
INSERT INTO #Fix SELECT N'B', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
-- C: produced from B, 50 pcs.
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=50, @AppUserId=1;
INSERT INTO #Fix SELECT N'C', NewId, MintedLotName FROM @cr;

DECLARE @A BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'A');
DECLARE @B BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'B');
DECLARE @C BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'C');

-- Record edges with EXPLICIT consumed counts: A->B consumes 96, B->C consumes 50.
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@A, @ConsumedPieceCount=96, @ProducedLotId=@B, @AppUserId=1;
DELETE FROM @rc;
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@B, @ConsumedPieceCount=50, @ProducedLotId=@C, @AppUserId=1;
GO

-- Test 1: Ancestors of C = B (Depth 1, consumed 50) and A (Depth 2, consumed 96).
DECLARE @C BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'C');
DECLARE @A BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'A');
DECLARE @B BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'B');

IF OBJECT_ID(N'tempdb..#anc') IS NOT NULL DROP TABLE #anc;
CREATE TABLE #anc (RelatedLotId BIGINT, RelatedLotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50),
                   RelationshipName NVARCHAR(100), PieceCount INT, UomCode NVARCHAR(20), Depth INT, Direction NVARCHAR(20));
INSERT INTO #anc EXEC Lots.Lot_GetGenealogyEdgeTree @LotId=@C, @Direction=N'Ancestors';

DECLARE @ancN INT = (SELECT COUNT(*) FROM #anc);
EXEC test.Assert_RowCount @TestName=N'[EdgeTree] C has 2 ancestors', @ExpectedCount=2, @ActualCount=@ancN;

DECLARE @aConsumed NVARCHAR(20) = CAST((SELECT PieceCount FROM #anc WHERE RelatedLotId=@A) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] A consumed=96 (edge, not lot qty 1000)',
    @Expected=N'96', @Actual=@aConsumed;
DECLARE @aDepth NVARCHAR(20) = CAST((SELECT Depth FROM #anc WHERE RelatedLotId=@A) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] A at Depth 2', @Expected=N'2', @Actual=@aDepth;
DECLARE @bConsumed NVARCHAR(20) = CAST((SELECT PieceCount FROM #anc WHERE RelatedLotId=@B) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] B consumed=50', @Expected=N'50', @Actual=@bConsumed;

DECLARE @uomOk BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #anc WHERE UomCode IS NULL) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[EdgeTree] every row has a non-null UomCode', @Condition=@uomOk;

DECLARE @allAnc BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #anc WHERE Direction<>N'Ancestor') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[EdgeTree] all rows Direction=Ancestor', @Condition=@allAnc;
DROP TABLE #anc;
GO

-- Test 2: Descendants of A = B (Depth 1, 96) and C (Depth 2, 50).
DECLARE @A BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'A');
DECLARE @C BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'C');
IF OBJECT_ID(N'tempdb..#dn') IS NOT NULL DROP TABLE #dn;
CREATE TABLE #dn (RelatedLotId BIGINT, RelatedLotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50),
                  RelationshipName NVARCHAR(100), PieceCount INT, UomCode NVARCHAR(20), Depth INT, Direction NVARCHAR(20));
INSERT INTO #dn EXEC Lots.Lot_GetGenealogyEdgeTree @LotId=@A, @Direction=N'Descendants';
DECLARE @dnN INT = (SELECT COUNT(*) FROM #dn);
EXEC test.Assert_RowCount @TestName=N'[EdgeTree] A has 2 descendants', @ExpectedCount=2, @ActualCount=@dnN;
DECLARE @cDepth NVARCHAR(20) = CAST((SELECT Depth FROM #dn WHERE RelatedLotId=@C) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] descendant C at Depth 2', @Expected=N'2', @Actual=@cDepth;
DROP TABLE #dn;
GO

-- Test 3: Both (default) = ancestors + descendants; empty for an isolated LOT.
DECLARE @B BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'B');
IF OBJECT_ID(N'tempdb..#bo') IS NOT NULL DROP TABLE #bo;
CREATE TABLE #bo (RelatedLotId BIGINT, RelatedLotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50),
                  RelationshipName NVARCHAR(100), PieceCount INT, UomCode NVARCHAR(20), Depth INT, Direction NVARCHAR(20));
INSERT INTO #bo EXEC Lots.Lot_GetGenealogyEdgeTree @LotId=@B;  -- default Both
DECLARE @boN INT = (SELECT COUNT(*) FROM #bo);
EXEC test.Assert_RowCount @TestName=N'[EdgeTree] B Both = 1 ancestor + 1 descendant = 2', @ExpectedCount=2, @ActualCount=@boN;
DROP TABLE #bo;

-- Isolated LOT (no edges) -> empty set.
DECLARE @OriginRcv2 BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @I2 BIGINT, @L2 BIGINT;
SELECT TOP 1 @I2=eil.ItemId, @L2=eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL) ORDER BY eil.LocationId;
DECLARE @cr2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr2 EXEC Lots.Lot_Create @ItemId=@I2, @LotOriginTypeId=@OriginRcv2,
    @CurrentLocationId=@L2, @PieceCount=10, @AppUserId=1;
DECLARE @Iso BIGINT = (SELECT NewId FROM @cr2);
INSERT INTO #Fix SELECT N'ISO', @Iso, (SELECT MintedLotName FROM @cr2);
IF OBJECT_ID(N'tempdb..#em') IS NOT NULL DROP TABLE #em;
CREATE TABLE #em (RelatedLotId BIGINT, RelatedLotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50),
                  RelationshipName NVARCHAR(100), PieceCount INT, UomCode NVARCHAR(20), Depth INT, Direction NVARCHAR(20));
INSERT INTO #em EXEC Lots.Lot_GetGenealogyEdgeTree @LotId=@Iso, @Direction=N'Both';
DECLARE @emN INT = (SELECT COUNT(*) FROM #em);
EXEC test.Assert_RowCount @TestName=N'[EdgeTree] isolated LOT returns empty set', @ExpectedCount=0, @ActualCount=@emN;
DROP TABLE #em;
GO

-- ---- cleanup (FK-safe: edges + closure before LOTs; LotEventLog from Create/Consume) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #Fix WHERE LotId IS NOT NULL;
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#Fix') IS NOT NULL DROP TABLE #Fix;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"`
Expected: FAIL — `Lots.Lot_GetGenealogyEdgeTree` does not exist (`Could not find stored procedure`).

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_Lot_GetGenealogyEdgeTree.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetGenealogyEdgeTree.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Recursive edge-walk genealogy for the LOT Genealogy & Traceability
--              report. Unlike the closure-backed Lots.Lot_GetGenealogyTree (which
--              flattens the DAG and loses per-edge quantity above depth 1), this
--              walks the Lots.LotGenealogy EDGE table so each row carries the actual
--              per-edge consumed PieceCount and the true tree depth.
--
--              READ proc (FDS-11-011): no @Status/@Message, no status row, ONE result
--              set, empty set = not found, no OUTPUT params.
--
--              @Direction ∈ Ancestors / Descendants / Both (default), case-insensitive,
--              singular/plural accepted, unrecognized -> Both.
--
--              A path-string cycle guard + OPTION(MAXRECURSION 100) bound the walk;
--              genealogy is a DAG by construction, the guard is defensive. A node
--              reachable by multiple distinct edges appears once per edge (each is a
--              real, separately-quantified consumption) -- intended.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetGenealogyEdgeTree
    @LotId     BIGINT,
    @Direction NVARCHAR(20) = N'Both'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Dir NVARCHAR(20) =
        CASE LOWER(LTRIM(RTRIM(ISNULL(@Direction, N'Both'))))
            WHEN N'ancestor'    THEN N'Ancestors'
            WHEN N'ancestors'   THEN N'Ancestors'
            WHEN N'descendant'  THEN N'Descendants'
            WHEN N'descendants' THEN N'Descendants'
            WHEN N'both'        THEN N'Both'
            ELSE N'Both'
        END;

    ;WITH Up AS (
        -- Ancestors: seed on the subject's direct parents, recurse up.
        SELECT g.ParentLotId AS RelatedLotId, g.RelationshipTypeId, g.PieceCount,
               1 AS Depth,
               CAST(N'/' + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        FROM Lots.LotGenealogy g
        WHERE g.ChildLotId = @LotId
        UNION ALL
        SELECT g.ParentLotId, g.RelationshipTypeId, g.PieceCount, u.Depth + 1,
               CAST(u.Path + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Up u ON g.ChildLotId = u.RelatedLotId
        WHERE u.Path NOT LIKE N'%/' + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/%'
    ),
    Dn AS (
        -- Descendants: seed on the subject's direct children, recurse down.
        SELECT g.ChildLotId AS RelatedLotId, g.RelationshipTypeId, g.PieceCount,
               1 AS Depth,
               CAST(N'/' + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        FROM Lots.LotGenealogy g
        WHERE g.ParentLotId = @LotId
        UNION ALL
        SELECT g.ChildLotId, g.RelationshipTypeId, g.PieceCount, d.Depth + 1,
               CAST(d.Path + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Dn d ON g.ParentLotId = d.RelatedLotId
        WHERE d.Path NOT LIKE N'%/' + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/%'
    )
    SELECT u.RelatedLotId,
           l.LotName        AS RelatedLotName,
           l.ItemId,
           i.PartNumber,
           rt.Name          AS RelationshipName,
           u.PieceCount,
           ISNULL(uom.Code, N'PCS') AS UomCode,
           u.Depth,
           u.Direction
    FROM (
        SELECT RelatedLotId, RelationshipTypeId, PieceCount, Depth,
               CAST(N'Ancestor' AS NVARCHAR(20)) AS Direction
        FROM Up   WHERE @Dir IN (N'Ancestors', N'Both')
        UNION ALL
        SELECT RelatedLotId, RelationshipTypeId, PieceCount, Depth,
               CAST(N'Descendant' AS NVARCHAR(20)) AS Direction
        FROM Dn   WHERE @Dir IN (N'Descendants', N'Both')
    ) u
    INNER JOIN Lots.Lot   l  ON l.Id  = u.RelatedLotId
    INNER JOIN Parts.Item i  ON i.Id  = l.ItemId
    INNER JOIN Lots.GenealogyRelationshipType rt ON rt.Id = u.RelationshipTypeId
    LEFT  JOIN Parts.Uom  uom ON uom.Id = i.UomId
    ORDER BY u.Direction, u.Depth, l.LotName
    OPTION (MAXRECURSION 100);
END;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"`
Expected: PASS — all `[EdgeTree]` assertions green (notably `A consumed=96`).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetGenealogyEdgeTree.sql sql/tests/0055_LotGenealogyReport/010_Lot_GetGenealogyEdgeTree.sql
git commit -m "feat(sql): Lot_GetGenealogyEdgeTree - recursive both-way genealogy with per-edge consumed qty"
```

---

### Task 2: `Lots.Lot_GetLifecycle` read proc

Chronological per-LOT event stream from `Lots.LotEventLog`, with a discrete Location column (chosen over `Lot_GetAttributeHistory`, which embeds location in its Detail string).

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetLifecycle.sql`
- Test: `sql/tests/0055_LotGenealogyReport/020_Lot_GetLifecycle.sql`

**Interfaces:**
- Consumes: `Lots.LotEventLog(LotId, LoggedAt, UserId, LocationId, TerminalLocationId, LogEventTypeId, Description)`, `Audit.LogEventType(Id, Name)`, `Location.Location(Id, Name)`, `Location.AppUser(Id, DisplayName)`. Fixtures call `Lots.Lot_Create` + `Lots.LotGenealogy_RecordConsumption` (both write `LotEventLog` rows).
- Produces: `Lots.Lot_GetLifecycle(@LotId BIGINT)` → `EventAtEt DATETIME2(3), EventTypeName NVARCHAR(100), LocationName NVARCHAR(200), OperatorName NVARCHAR(200), Description NVARCHAR(1000)`, ordered `LoggedAt ASC`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0055_LotGenealogyReport/020_Lot_GetLifecycle.sql`:

```sql
-- =============================================
-- 0055_LotGenealogyReport/020_Lot_GetLifecycle.sql
-- Per-LOT lifecycle timeline from Lots.LotEventLog. READ proc.
-- Create + consume writes >=2 LotEventLog rows (LotCreated, LotConsumed);
-- assert chronological order, ET projection, and populated event/type columns.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0055_LotGenealogyReport/020_Lot_GetLifecycle.sql';
GO

IF OBJECT_ID(N'tempdb..#LcFix') IS NOT NULL DROP TABLE #LcFix;
CREATE TABLE #LcFix (Tag NVARCHAR(10) PRIMARY KEY, LotId BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId=eil.ItemId, @CellId=eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId=eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=500, @AppUserId=1;
INSERT INTO #LcFix SELECT N'SRC', NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=100, @AppUserId=1;
INSERT INTO #LcFix SELECT N'PROD', NewId FROM @cr;

DECLARE @Src BIGINT=(SELECT LotId FROM #LcFix WHERE Tag=N'SRC');
DECLARE @Prod BIGINT=(SELECT LotId FROM #LcFix WHERE Tag=N'PROD');
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@Src, @ConsumedPieceCount=40, @ProducedLotId=@Prod, @AppUserId=1;
GO

-- Test: SRC lifecycle has >=2 rows (created + consumed), ascending, typed columns present.
DECLARE @Src BIGINT=(SELECT LotId FROM #LcFix WHERE Tag=N'SRC');
IF OBJECT_ID(N'tempdb..#lc') IS NOT NULL DROP TABLE #lc;
CREATE TABLE #lc (EventAtEt DATETIME2(3), EventTypeName NVARCHAR(100), LocationName NVARCHAR(200),
                  OperatorName NVARCHAR(200), Description NVARCHAR(1000));
INSERT INTO #lc EXEC Lots.Lot_GetLifecycle @LotId=@Src;

DECLARE @n INT = (SELECT COUNT(*) FROM #lc);
DECLARE @atLeast2 BIT = CASE WHEN @n >= 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Lifecycle] SRC has >= 2 events', @Condition=@atLeast2;

DECLARE @typedOk BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #lc WHERE EventTypeName IS NULL) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Lifecycle] every row has an EventTypeName', @Condition=@typedOk;

DECLARE @outOfOrder INT = (
    SELECT COUNT(*) FROM (
        SELECT EventAtEt, LAG(EventAtEt) OVER (ORDER BY (SELECT 1)) AS PrevAt
        FROM #lc
    ) x WHERE PrevAt IS NOT NULL AND EventAtEt < PrevAt);
DECLARE @ordered BIT = CASE WHEN @outOfOrder = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Lifecycle] rows ascending by EventAtEt', @Condition=@ordered;

-- Not-found LOT (id 0) -> empty set (no invented 404).
IF OBJECT_ID(N'tempdb..#lc0') IS NOT NULL DROP TABLE #lc0;
CREATE TABLE #lc0 (EventAtEt DATETIME2(3), EventTypeName NVARCHAR(100), LocationName NVARCHAR(200),
                   OperatorName NVARCHAR(200), Description NVARCHAR(1000));
INSERT INTO #lc0 EXEC Lots.Lot_GetLifecycle @LotId=0;
DECLARE @z INT = (SELECT COUNT(*) FROM #lc0);
EXEC test.Assert_RowCount @TestName=N'[Lifecycle] unknown LOT returns empty set', @ExpectedCount=0, @ActualCount=@z;
DROP TABLE #lc; DROP TABLE #lc0;
GO

-- ---- cleanup ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #LcFix WHERE LotId IS NOT NULL;
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#LcFix') IS NOT NULL DROP TABLE #LcFix;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"`
Expected: FAIL — `Lots.Lot_GetLifecycle` does not exist.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_Lot_GetLifecycle.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLifecycle.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Per-LOT lifecycle timeline for the traceability report. Projects the
--              append-only audit event stream Lots.LotEventLog for @LotId with a
--              DISCRETE Location column (COALESCE of the event's LocationId and the
--              recording TerminalLocationId), the event-type name, acting operator,
--              and description -- created / acted-on / closed, one row per event.
--
--              Chosen over Lots.Lot_GetAttributeHistory: that curated timeline bakes
--              location into its Detail string, whereas the report wants a Location
--              column and LotEventLog carries LocationId on every row.
--
--              READ proc (FDS-11-011): no status row, ONE result set, empty = not
--              found, no OUTPUT params. Timestamp converted UTC->Eastern at the read
--              boundary; ORDER BY on raw UTC LoggedAt (stable chronological).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLifecycle
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        CAST(el.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAtEt,
        et.Name              AS EventTypeName,
        loc.Name             AS LocationName,
        au.DisplayName       AS OperatorName,
        el.Description        AS Description
    FROM Lots.LotEventLog el
    INNER JOIN Audit.LogEventType et  ON et.Id  = el.LogEventTypeId
    LEFT  JOIN Location.Location   loc ON loc.Id = COALESCE(el.LocationId, el.TerminalLocationId)
    LEFT  JOIN Location.AppUser    au  ON au.Id  = el.UserId
    WHERE el.LotId = @LotId
    ORDER BY el.LoggedAt ASC;
END;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"`
Expected: PASS — all `[Lifecycle]` assertions green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetLifecycle.sql sql/tests/0055_LotGenealogyReport/020_Lot_GetLifecycle.sql
git commit -m "feat(sql): Lot_GetLifecycle - per-LOT event timeline with discrete Location column"
```

---

### Task 3: `Lots.Lot_GetShippedContainers` read proc

Every finished-good container the LOT reached — its own if it is an FG, plus the containers of all its FG descendants — each tagged with its FG LOT and Honda AIM shipper id.

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetShippedContainers.sql`
- Test: `sql/tests/0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql`

**Interfaces:**
- Consumes: `Lots.ContainerTray(ContainerId, FinishedGoodLotId, PartsClosedCount)`, `Lots.Container(Id, ItemId, CurrentLocationId, ContainerStatusCodeId, CompletedAt)`, `Lots.ContainerStatusCode(Id, Name)`, `Lots.ShippingLabel(ContainerId, AimShipperId, IsVoid, CreatedAt)`, `Lots.Lot(Id, LotName, ItemId)`, `Parts.Item(Id, PartNumber)`, `Location.Location(Id, Name)`, `Lots.LotGenealogy` (descendant reach via the Task-1 walk pattern). Fixture inserts a `Container` + `ContainerTray` + `ShippingLabel` directly and one `LotGenealogy` edge.
- Produces: `Lots.Lot_GetShippedContainers(@LotId BIGINT)` → `FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50), ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100), CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3)`, ordered `FinishedGoodLotName, ContainerId`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql`:

```sql
-- =============================================
-- 0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql
-- Descendant-aware shipped-container band. READ proc.
-- Fixture: SUB --consume--> FG; FG packed into a Container with an AIM ShippingLabel.
--   * GetShippedContainers(FG)  -> FG's own container (subject is an FG).
--   * GetShippedContainers(SUB) -> the SAME container, via descendant reach.
--   * GetShippedContainers(ISO) -> empty (no FG container in its descendants).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql';
GO

IF OBJECT_ID(N'tempdb..#ScFix') IS NOT NULL DROP TABLE #ScFix;
CREATE TABLE #ScFix (Tag NVARCHAR(10) PRIMARY KEY, Id BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId=eil.ItemId, @CellId=eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId=eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=300, @AppUserId=1;
INSERT INTO #ScFix SELECT N'SUB', NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=300, @AppUserId=1;
INSERT INTO #ScFix SELECT N'FG', NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=10, @AppUserId=1;
INSERT INTO #ScFix SELECT N'ISO', NewId FROM @cr;

DECLARE @Sub BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'SUB');
DECLARE @Fg  BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'FG');

-- SUB consumed into FG (descendant edge).
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@Sub, @ConsumedPieceCount=250, @ProducedLotId=@Fg, @AppUserId=1;

-- Pack FG into a Container with an AIM shipping label (direct inserts).
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
DECLARE @FgItem BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id=@Fg);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@FgItem, @Cfg, @CellId, 2, SYSUTCDATETIME(), 1);
DECLARE @Cid BIGINT = SCOPE_IDENTITY();
INSERT INTO #ScFix SELECT N'CID', @Cid;
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cid, 1, 250, SYSUTCDATETIME(), 1, N'Auto', @Fg);
DECLARE @LblType BIGINT = (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id);
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, IsVoid, CreatedAt, CreatedByUserId)
VALUES (@Cid, N'AIMTEST00013218', @LblType, 0, SYSUTCDATETIME(), 1);
GO

-- Test 1: FG (subject is itself an FG) -> its own container + AIM id.
DECLARE @Fg BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'FG');
IF OBJECT_ID(N'tempdb..#sf') IS NOT NULL DROP TABLE #sf;
CREATE TABLE #sf (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50),
                  ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100),
                  CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO #sf EXEC Lots.Lot_GetShippedContainers @LotId=@Fg;
DECLARE @sfN INT = (SELECT COUNT(*) FROM #sf);
EXEC test.Assert_RowCount @TestName=N'[Shipped] FG has 1 container', @ExpectedCount=1, @ActualCount=@sfN;
DECLARE @sfAim NVARCHAR(50) = (SELECT AimShipperId FROM #sf);
EXEC test.Assert_IsEqual @TestName=N'[Shipped] FG container carries the AIM id',
    @Expected=N'AIMTEST00013218', @Actual=@sfAim;
DROP TABLE #sf;
GO

-- Test 2: SUB (upstream) -> the same FG container, tagged with the FG LOT.
DECLARE @Sub BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'SUB');
DECLARE @Fg BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'FG');
IF OBJECT_ID(N'tempdb..#ss') IS NOT NULL DROP TABLE #ss;
CREATE TABLE #ss (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50),
                  ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100),
                  CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO #ss EXEC Lots.Lot_GetShippedContainers @LotId=@Sub;
DECLARE @ssN INT = (SELECT COUNT(*) FROM #ss);
EXEC test.Assert_RowCount @TestName=N'[Shipped] SUB reaches 1 FG container (via descendant)', @ExpectedCount=1, @ActualCount=@ssN;
DECLARE @ssFg NVARCHAR(20) = CAST((SELECT FinishedGoodLotId FROM #ss) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[Shipped] SUB container tagged with the FG LOT',
    @Expected=CAST(@Fg AS NVARCHAR(20)), @Actual=@ssFg;
DROP TABLE #ss;
GO

-- Test 3: ISO (no FG container in its descendants) -> empty.
DECLARE @Iso BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'ISO');
IF OBJECT_ID(N'tempdb..#si') IS NOT NULL DROP TABLE #si;
CREATE TABLE #si (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50),
                  ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100),
                  CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO #si EXEC Lots.Lot_GetShippedContainers @LotId=@Iso;
DECLARE @siN INT = (SELECT COUNT(*) FROM #si);
EXEC test.Assert_RowCount @TestName=N'[Shipped] in-process LOT returns empty band', @ExpectedCount=0, @ActualCount=@siN;
DROP TABLE #si;
GO

-- ---- cleanup (containers/labels before LOTs; edges before LOTs) ----
DECLARE @Cid BIGINT = (SELECT Id FROM #ScFix WHERE Tag=N'CID');
DELETE FROM Lots.ShippingLabel WHERE ContainerId=@Cid;
DELETE FROM Lots.ContainerTray WHERE ContainerId=@Cid;
DELETE FROM Lots.Container WHERE Id=@Cid;
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Id FROM #ScFix WHERE Tag IN (N'SUB',N'FG',N'ISO');
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#ScFix') IS NOT NULL DROP TABLE #ScFix;
GO

EXEC test.EndTestFile;
GO
```

> **Fixture note for the implementer:** verify the exact column names of `Lots.Container`, `Lots.ContainerTray`, `Lots.ShippingLabel` against migration `0028_arc2_phase6_assembly.sql` and the migration that added `ContainerTray.FinishedGoodLotId` (0034, referenced by `Lot_GetLinkedContainer`) before running — adjust the direct-insert column lists if a NOT NULL column without a default is missing. `ContainerStatusCodeId = 2` is Complete; `LabelTypeCodeId` uses the first seeded label type.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"`
Expected: FAIL — `Lots.Lot_GetShippedContainers` does not exist.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_Lot_GetShippedContainers.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetShippedContainers.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: The shipped-container / Honda-AIM band for the LOT Genealogy &
--              Traceability report. Returns every finished-good container the LOT
--              reached: the subject LOT itself PLUS all of its genealogy descendants
--              (recursive edge walk), joined to any container they were packed into
--              via Lots.ContainerTray.FinishedGoodLotId, with the active (non-void)
--              AIM shipper id off the shipping label. Each row names its FG LOT so a
--              multi-descendant band stays legible.
--
--              A subject that is itself an FG degenerates correctly (its own container
--              is included because the descendant set is seeded with the subject).
--
--              READ proc (FDS-11-011): no status row, ONE result set, empty = the LOT
--              has reached no FG container yet, no OUTPUT params. CompletedAt is ET at
--              the read boundary. Lot_GetLinkedContainer remains the single-LOT lookup;
--              this proc is the report's descendant-aware view.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetShippedContainers
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Reach AS (
        -- Seed with the subject itself, then walk down every consumption edge.
        SELECT @LotId AS LotId,
               CAST(N'/' + CAST(@LotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        UNION ALL
        SELECT g.ChildLotId,
               CAST(r.Path + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Reach r ON g.ParentLotId = r.LotId
        WHERE r.Path NOT LIKE N'%/' + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/%'
    )
    SELECT
        ct.FinishedGoodLotId,
        fgl.LotName          AS FinishedGoodLotName,
        fgi.PartNumber       AS FinishedGoodPartNumber,
        c.Id                 AS ContainerId,
        sl.AimShipperId,
        ct.PartsClosedCount  AS Quantity,
        csc.Name             AS ContainerStatusName,
        loc.Name             AS CurrentLocationName,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt
    FROM Lots.ContainerTray ct
    INNER JOIN (SELECT DISTINCT LotId FROM Reach) r ON r.LotId = ct.FinishedGoodLotId
    INNER JOIN Lots.Container            c   ON c.Id   = ct.ContainerId
    INNER JOIN Lots.Lot                  fgl ON fgl.Id = ct.FinishedGoodLotId
    INNER JOIN Parts.Item                fgi ON fgi.Id = fgl.ItemId
    LEFT  JOIN Lots.ContainerStatusCode  csc ON csc.Id = c.ContainerStatusCodeId
    LEFT  JOIN Location.Location         loc ON loc.Id = c.CurrentLocationId
    OUTER APPLY (
        SELECT TOP 1 s.AimShipperId
        FROM Lots.ShippingLabel s
        WHERE s.ContainerId = c.Id AND s.IsVoid = 0
        ORDER BY s.CreatedAt DESC
    ) sl
    ORDER BY fgl.LotName, c.Id
    OPTION (MAXRECURSION 100);
END;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./sql/tests/Run-Tests.ps1 -Filter "LotGenealogyReport"`
Expected: PASS — all `[Shipped]` assertions green (all three test files now green together).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetShippedContainers.sql sql/tests/0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql
git commit -m "feat(sql): Lot_GetShippedContainers - descendant-aware FG containers with AIM ids"
```

---

### Task 4: Report — genealogy bands (consumed-qty fix + both directions)

Fix the existing Genealogy band's consumed-quantity binding and split it into two full-depth bands ("Made From · Ancestors", "Used In · Descendants") driven by `Lot_GetGenealogyEdgeTree`. Report edits go through the `ignition-reporting` skill (decode/edit `data.bin`), then deploy + render-verify.

**Files:**
- Modify (via `ignition-reporting` skill): `ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin`
- Reference: `ignition-context-pack/10_reporting_module.md`, `docs/superpowers/specs/2026-08-11-lot-genealogy-traceability-report-design.md`

**Interfaces:**
- Consumes: `Lots.Lot_GetGenealogyEdgeTree(@LotId, @Direction)` (Task 1). The report's LOT id parameter (already on the report — inspect the decoded params to get its exact token name; referred to below as `{LotID}`).
- Produces: an edited `Lot Detail` report with corrected/added genealogy bands; consumed by Task 5 (same `data.bin`).

- [ ] **Step 1: Invoke the skill and decode the report**

Invoke the `ignition-reporting` skill. Use its codec to decode `Lot Detail/data.bin` and inspect: (a) the existing parameters (find the LOT-id param token name), (b) the current Genealogy data source SQL and its band, (c) the exact column/field bindings that currently show the wrong Qty.

- [ ] **Step 2: Add the ancestors data source**

Add a report data source (embedded SQL, positional `?`) named `GenealogyAncestors`:

```sql
EXEC Lots.Lot_GetGenealogyEdgeTree ?, 'Ancestors'
```
Bind the single `?` to the report's LOT-id parameter. (Direction is a SQL literal, not a param, so only one token binds.)

- [ ] **Step 3: Add the descendants data source**

Add a second data source `GenealogyDescendants`:

```sql
EXEC Lots.Lot_GetGenealogyEdgeTree ?, 'Descendants'
```
Bind `?` to the same LOT-id parameter.

- [ ] **Step 4: Rebuild the two genealogy bands**

- Rename the existing "Genealogy" band to **"Made From · Ancestors"** (ASCII middle dot is fine in report text — the middle-dot mojibake rule is a `sqlcmd`/SQL-seed concern, not ReportMill; if in doubt use a hyphen "Made From - Ancestors"). Point it at `GenealogyAncestors`.
- Columns: `RelatedLotName` (Related LOT), `PartNumber` (Part), `RelationshipName` (Relationship), and **`PieceCount` + `UomCode`** in the Consumed column — this replaces the wrong lot-quantity binding. Indent the Related LOT cell by `Depth` (e.g. left-pad / indent expression keyed on the `Depth` field) so multi-level ancestry reads as a tree.
- Add a **"Used In · Descendants"** band below it, bound to `GenealogyDescendants`, same columns but the qty header reads **Contributed**.

- [ ] **Step 5: Deploy and render-verify**

Run `.\scan.ps1`, then render the report against the running gateway for a LOT that has both ancestors and descendants with partial consumption (use a seeded/demo LOT, e.g. via `Seed-Demo.ps1` — a machined SubAssembly). Verify per the skill's render-verify step:
- Consumed/Contributed columns show the **per-edge** counts (a partially-consumed ancestor shows its consumed share, not its full lot quantity).
- Ancestors recurse past depth 1; descendants appear in their own band.
- No Component/rendering errors; bands populate.

- [ ] **Step 6: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "feat(reports): Lot Detail genealogy - per-edge consumed qty + both-direction full-depth bands"
```

> If `scan.ps1` also touched a `resource.json` under the report folder, stage that explicit path too. Do not stage the report's `thumbnail.png`/generated binaries beyond `data.bin` (gitignored per project convention).

---

### Task 5: Report — containers + lifecycle bands

Add the shipped-container band (`Lot_GetShippedContainers`) and the lifecycle band (`Lot_GetLifecycle`) to the same report, then deploy + render-verify the full five-band report.

**Files:**
- Modify (via `ignition-reporting` skill): `ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin`

**Interfaces:**
- Consumes: `Lots.Lot_GetShippedContainers(@LotId)` (Task 3), `Lots.Lot_GetLifecycle(@LotId)` (Task 2), the report LOT-id parameter, and the Task-4 genealogy bands (same `data.bin`).
- Produces: the finished LOT Genealogy & Traceability report (all five bands).

- [ ] **Step 1: Add the containers data source**

Invoke the `ignition-reporting` skill, decode the (Task-4-updated) `data.bin`, and add data source `ShippedContainers`:

```sql
EXEC Lots.Lot_GetShippedContainers ?
```
Bind `?` to the LOT-id parameter.

- [ ] **Step 2: Add the Containers band**

Add a **"Containers"** band bound to `ShippedContainers`. Columns: `FinishedGoodLotName` (FG LOT), `FinishedGoodPartNumber` (FG Part), `ContainerId` (Container), `AimShipperId` (AIM Shipper ID), `Quantity`, `ContainerStatusName` (Status), `CurrentLocationName` (Location). The band renders empty (no rows) when the LOT has reached no FG container — that is the correct in-process display.

- [ ] **Step 3: Add the lifecycle data source**

Add data source `Lifecycle`:

```sql
EXEC Lots.Lot_GetLifecycle ?
```
Bind `?` to the LOT-id parameter.

- [ ] **Step 4: Add the Lifecycle band**

Add a **"Lifecycle"** band bound to `Lifecycle`. Columns: `EventAtEt` (Timestamp (ET) — format `MM-dd HH:mm:ss` or `yyyy-MM-dd HH:mm:ss`), `EventTypeName` (Event), `LocationName` (Location), `OperatorName` (Operator). Rows are already chronological from the proc — no report-side sort needed.

- [ ] **Step 5: Deploy and render-verify the full report**

Run `.\scan.ps1`, then render the full report against the gateway for:
- a **finished-good** LOT (Containers band shows its own AIM-labeled container; Lifecycle shows created → … → closed);
- an **upstream sub-assembly** LOT (Containers band shows its descendant FG containers, each tagged with the FG LOT);
- an **in-process** LOT (Containers band empty; other bands populate).

Confirm: all five bands present and correctly ordered (identity → Made From → Used In → Containers → Lifecycle); timestamps display in ET; no rendering errors.

- [ ] **Step 6: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "feat(reports): Lot Detail - add shipped-container (AIM) and lifecycle timeline bands"
```

---

## Self-Review

**Spec coverage** (each spec section → task):

- §2 goal "fix consumed qty" → Task 1 proc (`PieceCount`) + Task 4 Step 4 (rebind Consumed column). ✓
- §2 goal "both directions, full depth" → Task 1 (`@Direction` recursive walk) + Task 4 (two bands). ✓
- §2 goal "shipped containers + AIM" → Task 3 + Task 5 Steps 1-2. ✓
- §2 goal "lifecycle w/ location + timestamp" → Task 2 + Task 5 Steps 3-4. ✓
- §4 data sources → all pre-existing tables used; no schema change (none of Tasks 1-5 create tables). ✓
- §5.1 `Lot_GetGenealogyEdgeTree` → Task 1 (columns, `@Direction` normalization, MAXRECURSION, cycle guard all present). ✓
- §5.2 `Lot_GetLifecycle` (from `Lots.LotEventLog`, discrete Location) → Task 2. ✓
- §5.3 `Lot_GetShippedContainers` (descendant-aware, FG-tagged) → Task 3. ✓
- §6 five-band layout → Task 4 (bands 1-3: identity untouched, ancestors, descendants) + Task 5 (bands 4-5). ✓
- §7 consumed-qty provenance → confirmed report-only in research; Task 4 is report-only (no proc fix). Task 1's `A consumed=96` test also guards the edge-qty semantics. ✓
- §8 assumptions (containers follow descendants; UOM default PCS; depth cap) → Task 3 recursive reach; Task 1 `ISNULL(uom.Code,'PCS')`; `OPTION(MAXRECURSION 100)`. ✓
- §9 testing → Tasks 1-3 each carry the spec's enumerated cases (partial-consumption 96, branching descendant, direction variants, not-found, UOM, FG vs upstream vs in-process container, lifecycle order). ✓

**Placeholder scan:** No TBD/TODO. The two advisory notes (Task 3 fixture column-verification; Task 4 `scan.ps1` resource.json staging) are concrete verification instructions, not deferred work. Report-band manipulation is delegated to the `ignition-reporting` skill by design (binary `data.bin` cannot be hand-authored in-plan) with exact data-source SQL, band names, and column bindings specified.

**Type consistency:** Proc names and column names are identical across definition (Task N Step 3), test temp-table shapes (Step 1), and report data-source references (Tasks 4-5): `Lot_GetGenealogyEdgeTree`/`RelatedLotName`/`PieceCount`/`UomCode`/`Depth`/`Direction`; `Lot_GetLifecycle`/`EventAtEt`/`EventTypeName`/`LocationName`/`OperatorName`; `Lot_GetShippedContainers`/`FinishedGoodLotName`/`AimShipperId`/`Quantity`. Param signatures match between test `EXEC` and proc definition.
