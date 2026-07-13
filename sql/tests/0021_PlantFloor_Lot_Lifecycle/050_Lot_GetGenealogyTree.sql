-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/050_Lot_GetGenealogyTree.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for the Phase 2 Task 5 / G3 genealogy + history READ procs
--               (spec section 4.3). All four are READ procs: no @Status/@Message,
--               no status row, one result set, empty set = not found.
--
--                 * Lots.Lot_GetGenealogyTree(@LotId, @Direction) -- closure-backed
--                   ancestors / descendants / both walk.
--                 * Lots.Lot_GetParents(@LotId)   -- one-hop up (LotGenealogy edges).
--                 * Lots.Lot_GetChildren(@LotId)  -- one-hop down (LotGenealogy edges).
--                 * Lots.Lot_GetAttributeHistory(@LotId) -- UNION of LotAttributeChange
--                   + LotStatusHistory + LotMovement, normalized + time-ordered.
--
--               A genuine 3-level tree is built with the REAL Lots.Lot_Split proc so
--               the closure/edge rows the reads project are exactly what the writers
--               produce:
--                   GP  --split 2-->  P1, P2          (P1, P2 are GP's direct children, and are themselves parents of L1/L2)
--                   P1  --split 2-->  P1-01, P1-02    (leaves; GP's grandchildren)
--               Descendants(GP) = {P1, P2, P1-01, P1-02} (P1-01/-02 at Depth 2).
--               Ancestors(P1-01) = {P1 (Depth 1), GP (Depth 2)}.
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so Lot_Create needs
--               no Tool/Cavity. Every fixture LOT id is tracked in #GenFix for
--               FK-safe teardown. Note: Lot_Split's residual-0 auto-Close means a
--               fully-split parent goes Closed -- harmless for the reads.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/050_Lot_GetGenealogyTree.sql';
GO

-- ---- shared fixtures ----
IF OBJECT_ID(N'tempdb..#GenFix') IS NOT NULL DROP TABLE #GenFix;
CREATE TABLE #GenFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)   -- uncapped: fixture PieceCounts exceed the 24-30 seed basket caps
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- GP: grandparent, 100 pcs.
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #GenFix (Tag, LotId, LotName) SELECT N'GP', NewId, MintedLotName FROM @cr;

-- Split GP into P1 (40) + P2 (40); residual 20 stays on GP (GP NOT Closed).
DECLARE @GpId BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'GP');
DECLARE @splitJson1 NVARCHAR(MAX) =
    N'[{"pieceCount":40,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'},'
  + N'{"pieceCount":40,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'}]';
IF OBJECT_ID(N'tempdb..#sp1') IS NOT NULL DROP TABLE #sp1;
CREATE TABLE #sp1 (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #sp1 EXEC Lots.Lot_Split @ParentLotId = @GpId, @ChildrenJson = @splitJson1, @AppUserId = 1;
-- Capture the two parents by ordinal-of-name (-01 / -02).
INSERT INTO #GenFix (Tag, LotId, LotName)
    SELECT N'P1', ChildLotId, ChildLotName FROM #sp1 WHERE ChildLotName LIKE N'%-01';
INSERT INTO #GenFix (Tag, LotId, LotName)
    SELECT N'P2', ChildLotId, ChildLotName FROM #sp1 WHERE ChildLotName LIKE N'%-02';
DROP TABLE #sp1;

-- Split P1 into two leaves P1-01, P1-02 (20 + 20 = 40 -> P1 residual 0 -> Closed).
DECLARE @P1Id BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'P1');
DECLARE @splitJson2 NVARCHAR(MAX) =
    N'[{"pieceCount":20,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'},'
  + N'{"pieceCount":20,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'}]';
IF OBJECT_ID(N'tempdb..#sp2') IS NOT NULL DROP TABLE #sp2;
CREATE TABLE #sp2 (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #sp2 EXEC Lots.Lot_Split @ParentLotId = @P1Id, @ChildrenJson = @splitJson2, @AppUserId = 1;
INSERT INTO #GenFix (Tag, LotId, LotName)
    SELECT N'L1', ChildLotId, ChildLotName FROM #sp2 WHERE ChildLotName LIKE N'%-01-01';
INSERT INTO #GenFix (Tag, LotId, LotName)
    SELECT N'L2', ChildLotId, ChildLotName FROM #sp2 WHERE ChildLotName LIKE N'%-01-02';
DROP TABLE #sp2;

-- HIST: a standalone LOT used only for the attribute-history union test. Updated
-- (PieceCount change -> LotAttributeChange) + moved (LotMovement) so the union has
-- all three stream kinds (Attribute, Status from create, Movement).
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 60, @AppUserId = 1;
INSERT INTO #GenFix (Tag, LotId, LotName) SELECT N'HIST', NewId, MintedLotName FROM @cr;
GO

-- =============================================
-- Test 1: Descendants of GP. The closure has GP -> {P1, P2} at depth 1 and
--         GP -> {L1, L2} at depth 2 (4 descendant rows total, self-row excluded
--         by Depth > 0). A depth-2 leaf is present with Depth = 2.
-- =============================================
DECLARE @Gp BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'GP');
DECLARE @L1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'L1');

IF OBJECT_ID(N'tempdb..#td') IS NOT NULL DROP TABLE #td;
CREATE TABLE #td (LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50), Depth INT, Direction NVARCHAR(20));
INSERT INTO #td EXEC Lots.Lot_GetGenealogyTree @LotId = @Gp, @Direction = N'Descendants';

DECLARE @descCount INT = (SELECT COUNT(*) FROM #td);
EXEC test.Assert_RowCount @TestName = N'[Tree] GP has 4 descendants', @ExpectedCount = 4, @ActualCount = @descCount;

DECLARE @allDesc BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #td WHERE Direction <> N'Descendant') AND @descCount = 4 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Tree] all rows tagged Direction=Descendant', @Condition = @allDesc;

DECLARE @leafDepth NVARCHAR(20) = CAST((SELECT Depth FROM #td WHERE LotId = @L1) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Tree] depth-2 leaf present with Depth=2',
    @Expected = N'2', @Actual = @leafDepth;
DROP TABLE #td;
GO

-- =============================================
-- Test 2: Ancestors of a leaf (L1). Closure: P1 -> L1 depth 1, GP -> L1 depth 2.
--         Two ancestor rows, P1 at Depth 1 and GP at Depth 2.
-- =============================================
DECLARE @L1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'L1');
DECLARE @P1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'P1');
DECLARE @Gp BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'GP');

IF OBJECT_ID(N'tempdb..#ta') IS NOT NULL DROP TABLE #ta;
CREATE TABLE #ta (LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50), Depth INT, Direction NVARCHAR(20));
INSERT INTO #ta EXEC Lots.Lot_GetGenealogyTree @LotId = @L1, @Direction = N'Ancestors';

DECLARE @ancCount INT = (SELECT COUNT(*) FROM #ta);
EXEC test.Assert_RowCount @TestName = N'[Tree] leaf has 2 ancestors', @ExpectedCount = 2, @ActualCount = @ancCount;

DECLARE @p1Depth NVARCHAR(20) = CAST((SELECT Depth FROM #ta WHERE LotId = @P1) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Tree] direct parent P1 at Depth 1',
    @Expected = N'1', @Actual = @p1Depth;

DECLARE @gpDepth NVARCHAR(20) = CAST((SELECT Depth FROM #ta WHERE LotId = @Gp) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Tree] grandparent GP at Depth 2',
    @Expected = N'2', @Actual = @gpDepth;

DECLARE @allAnc BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #ta WHERE Direction <> N'Ancestor') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Tree] all rows tagged Direction=Ancestor', @Condition = @allAnc;
DROP TABLE #ta;
GO

-- =============================================
-- Test 3: Both (default) = ancestors UNION ALL descendants. For P1: ancestors =
--         {GP} (1), descendants = {L1, L2} (2) -> 3 rows total.
-- =============================================
DECLARE @P1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'P1');

IF OBJECT_ID(N'tempdb..#tb') IS NOT NULL DROP TABLE #tb;
CREATE TABLE #tb (LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50), Depth INT, Direction NVARCHAR(20));
INSERT INTO #tb EXEC Lots.Lot_GetGenealogyTree @LotId = @P1, @Direction = N'Both';

DECLARE @ancN INT = (SELECT COUNT(*) FROM #tb WHERE Direction = N'Ancestor');
DECLARE @descN INT = (SELECT COUNT(*) FROM #tb WHERE Direction = N'Descendant');
DECLARE @bothN INT = (SELECT COUNT(*) FROM #tb);
EXEC test.Assert_RowCount @TestName = N'[Tree] Both = ancestors(1) + descendants(2) = 3', @ExpectedCount = 3, @ActualCount = @bothN;

DECLARE @bothSum BIT = CASE WHEN @bothN = @ancN + @descN THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Tree] Both count equals ancestors + descendants', @Condition = @bothSum;

-- Default (@Direction omitted) behaves as Both.
IF OBJECT_ID(N'tempdb..#tbd') IS NOT NULL DROP TABLE #tbd;
CREATE TABLE #tbd (LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50), Depth INT, Direction NVARCHAR(20));
INSERT INTO #tbd EXEC Lots.Lot_GetGenealogyTree @LotId = @P1;
DECLARE @defN INT = (SELECT COUNT(*) FROM #tbd);
EXEC test.Assert_RowCount @TestName = N'[Tree] default @Direction acts as Both (3 rows)', @ExpectedCount = 3, @ActualCount = @defN;
DROP TABLE #tb;
DROP TABLE #tbd;
GO

-- =============================================
-- Test 4: Lot_GetParents of a leaf returns EXACTLY its direct parent (one row),
--         with the Split RelationshipType resolved.
-- =============================================
DECLARE @L1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'L1');
DECLARE @P1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'P1');

IF OBJECT_ID(N'tempdb..#par') IS NOT NULL DROP TABLE #par;
CREATE TABLE #par (ParentLotId BIGINT, ParentLotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50),
                   RelationshipTypeCode NVARCHAR(20), RelationshipTypeName NVARCHAR(100), PieceCount INT,
                   EventUserId BIGINT, EventUserName NVARCHAR(200), EventAt DATETIME2(3));
INSERT INTO #par EXEC Lots.Lot_GetParents @LotId = @L1;

DECLARE @parCount INT = (SELECT COUNT(*) FROM #par);
EXEC test.Assert_RowCount @TestName = N'[Parents] leaf has exactly one direct parent', @ExpectedCount = 1, @ActualCount = @parCount;

DECLARE @parId BIGINT = (SELECT ParentLotId FROM #par);
DECLARE @parMatch BIT = CASE WHEN @parId = @P1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Parents] direct parent is P1', @Condition = @parMatch;

DECLARE @relCode NVARCHAR(20) = (SELECT RelationshipTypeCode FROM #par);
EXEC test.Assert_IsEqual @TestName = N'[Parents] relationship is Split', @Expected = N'Split', @Actual = @relCode;
DROP TABLE #par;
GO

-- =============================================
-- Test 5: Lot_GetChildren of a parent (P1) returns its direct children only
--         (L1, L2) -- NOT grandchildren, NOT the grandparent's other branch (P2).
-- =============================================
DECLARE @P1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'P1');
DECLARE @L1 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'L1');
DECLARE @L2 BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'L2');

IF OBJECT_ID(N'tempdb..#chl') IS NOT NULL DROP TABLE #chl;
CREATE TABLE #chl (ChildLotId BIGINT, ChildLotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50),
                   RelationshipTypeCode NVARCHAR(20), RelationshipTypeName NVARCHAR(100), PieceCount INT,
                   EventUserId BIGINT, EventUserName NVARCHAR(200), EventAt DATETIME2(3));
INSERT INTO #chl EXEC Lots.Lot_GetChildren @LotId = @P1;

DECLARE @chlCount INT = (SELECT COUNT(*) FROM #chl);
EXEC test.Assert_RowCount @TestName = N'[Children] P1 has exactly 2 direct children', @ExpectedCount = 2, @ActualCount = @chlCount;

DECLARE @chlMatch BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #chl WHERE ChildLotId NOT IN (@L1, @L2))
                              AND EXISTS (SELECT 1 FROM #chl WHERE ChildLotId = @L1)
                              AND EXISTS (SELECT 1 FROM #chl WHERE ChildLotId = @L2)
                         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Children] direct children are exactly L1 and L2', @Condition = @chlMatch;

-- A leaf has no children -> empty result set.
IF OBJECT_ID(N'tempdb..#chl2') IS NOT NULL DROP TABLE #chl2;
CREATE TABLE #chl2 (ChildLotId BIGINT, ChildLotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50),
                    RelationshipTypeCode NVARCHAR(20), RelationshipTypeName NVARCHAR(100), PieceCount INT,
                    EventUserId BIGINT, EventUserName NVARCHAR(200), EventAt DATETIME2(3));
INSERT INTO #chl2 EXEC Lots.Lot_GetChildren @LotId = @L1;
DECLARE @leafChildren INT = (SELECT COUNT(*) FROM #chl2);
EXEC test.Assert_RowCount @TestName = N'[Children] leaf has no children (empty set)', @ExpectedCount = 0, @ActualCount = @leafChildren;
DROP TABLE #chl;
DROP TABLE #chl2;
GO

-- =============================================
-- Test 6: Lot_GetAttributeHistory unions the three streams. After a Lot_Update
--         (PieceCount change -> Attribute) + a Lot_MoveTo (Movement) on HIST -- on
--         top of the create-time Status + first Movement rows -- the proc returns
--         >= 2 rows spanning >= 2 distinct EventKinds, ordered ascending by EventAt.
--         The two mutations are asserted Status=1 so a silent failure (which would
--         leave only Lot_Create's own Status+Movement rows) is a test failure, not a
--         false pass.
-- =============================================
SET XACT_ABORT ON;
DECLARE @Hist BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'HIST');
DECLARE @HistLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @Hist);

-- Attribute change.
DECLARE @upd TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @upd EXEC Lots.Lot_Update @LotId = @Hist, @PieceCount = 55, @AppUserId = 1;

DECLARE @updStatus BIT = (SELECT TOP 1 Status FROM @upd);
EXEC test.Assert_IsTrue @TestName = N'[History] Lot_Update succeeded (Status=1)', @Condition = @updStatus;

-- Movement to any OTHER active location (Lot_MoveTo does not gate destination on
-- eligibility; it only requires the destination to exist and differ).
DECLARE @MoveTo BIGINT = (SELECT TOP 1 Id FROM Location.Location
                          WHERE DeprecatedAt IS NULL AND Id <> @HistLoc ORDER BY Id);
EXEC test.Assert_IsNotNull @TestName = N'[History] a destination location resolved for MoveTo', @Value = @MoveTo;

DECLARE @mv TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @mv EXEC Lots.Lot_MoveTo @LotId = @Hist, @ToLocationId = @MoveTo, @AppUserId = 1;

DECLARE @mvStatus BIT = (SELECT TOP 1 Status FROM @mv);
EXEC test.Assert_IsTrue @TestName = N'[History] Lot_MoveTo succeeded (Status=1)', @Condition = @mvStatus;

IF OBJECT_ID(N'tempdb..#hist') IS NOT NULL DROP TABLE #hist;
CREATE TABLE #hist (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO #hist EXEC Lots.Lot_GetAttributeHistory @LotId = @Hist;

DECLARE @histCount INT = (SELECT COUNT(*) FROM #hist);
DECLARE @histAtLeast2 BIT = CASE WHEN @histCount >= 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[History] returns >= 2 rows', @Condition = @histAtLeast2;

DECLARE @kinds INT = (SELECT COUNT(DISTINCT EventKind) FROM #hist);
DECLARE @kindsAtLeast2 BIT = CASE WHEN @kinds >= 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[History] spans >= 2 distinct EventKinds', @Condition = @kindsAtLeast2;

-- Attribute + Movement streams both present, and specifically the rows produced by
-- the two mutations above (not merely the create-time Status/Movement). The
-- Attribute Detail format is '<AttributeName>: <Old> -> <New>', so the PieceCount
-- change surfaces as 'PieceCount: ...' (see Lots.Lot_GetAttributeHistory).
DECLARE @hasAttr INT = (SELECT COUNT(*) FROM #hist
                        WHERE EventKind = N'Attribute' AND Detail LIKE N'PieceCount%');
DECLARE @hasAttrBit BIT = CASE WHEN @hasAttr >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[History] Attribute stream present (PieceCount change row)', @Condition = @hasAttrBit;

DECLARE @hasMove INT = (SELECT COUNT(*) FROM #hist WHERE EventKind = N'Movement');
DECLARE @hasMoveBit BIT = CASE WHEN @hasMove >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[History] Movement stream present', @Condition = @hasMoveBit;

-- Ordered ascending by EventAt (no row precedes its predecessor in time).
DECLARE @outOfOrder INT = (
    SELECT COUNT(*) FROM (
        SELECT EventAt, LAG(EventAt) OVER (ORDER BY (SELECT 1)) AS PrevAt,
               ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS rn
        FROM #hist
    ) x WHERE PrevAt IS NOT NULL AND EventAt < PrevAt);
-- NOTE: the proc fixes the row order; the window above re-reads physical order,
-- which for a freshly populated temp table from a single ordered INSERT-EXEC equals
-- the proc's output order. A non-zero count means the proc did NOT order ascending.
DECLARE @ordered BIT = CASE WHEN @outOfOrder = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[History] rows ascending by EventAt', @Condition = @ordered;
DROP TABLE #hist;
GO

-- =============================================
-- Test 7: empty-genealogy LOT -> empty tree result set (no invented 404 row).
-- =============================================
DECLARE @Hist BIGINT = (SELECT LotId FROM #GenFix WHERE Tag = N'HIST');
IF OBJECT_ID(N'tempdb..#te') IS NOT NULL DROP TABLE #te;
CREATE TABLE #te (LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemCode NVARCHAR(50), Depth INT, Direction NVARCHAR(20));
INSERT INTO #te EXEC Lots.Lot_GetGenealogyTree @LotId = @Hist, @Direction = N'Both';
DECLARE @emptyN INT = (SELECT COUNT(*) FROM #te);
EXEC test.Assert_RowCount @TestName = N'[Tree] LOT with no genealogy returns empty set', @ExpectedCount = 0, @ActualCount = @emptyN;
DROP TABLE #te;
GO

-- ---- cleanup (FK-safe: child rows -> LOTs; null self-ref ParentLotId first) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #GenFix WHERE LotId IS NOT NULL;

DELETE FROM Lots.LotGenealogy
    WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure
    WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);

UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#GenFix') IS NOT NULL DROP TABLE #GenFix;
GO

EXEC test.EndTestFile;
GO
