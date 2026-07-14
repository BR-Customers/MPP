-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for Lots.Lot_Split (Phase 2 Task 2 / G2). Asserts the
--               Option-A multi-row return shape (one row per minted child, with
--               Status/Message repeated), the parent-derived '-NN' sublot suffix,
--               B4 closure maintenance (parent->child depth 1; grandparent->child
--               depth 2 on a 2-level tree), parent PieceCount reduction +
--               auto-Close at residual 0, and the validation rejections
--               (sum-exceeds-parent; >99 sublots).
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so no Tool /
--               Cavity setup is required. Split children are Machining LOTs with
--               ToolId/ToolCavityId NULL anyway. Fixture parent LOTs carry the
--               standard MESL%% LotName (Lot_Create auto-mints); split children
--               carry the parent-derived <parent>-NN name. Cleanup is scoped to
--               the specific LOT ids created here (parents + descendants) so
--               other suites' LOTs are untouched.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql';
GO

-- ---- shared fixtures ----
-- Track every LOT id this suite touches (parents + minted children) in a
-- persistent temp table so the FK-safe cleanup at the end can sweep them all.
IF OBJECT_ID(N'tempdb..#SplitFix') IS NOT NULL DROP TABLE #SplitFix;
CREATE TABLE #SplitFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
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

-- P_FULL: parent at PieceCount=50, split 25+25 -> residual 0 -> Closed.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 50, @AppUserId = 1;
INSERT INTO #SplitFix (Tag, LotId, LotName)
    SELECT N'P_FULL', NewId, MintedLotName FROM @cr;

-- P_GP: grandparent at PieceCount=100 for the 2-level closure test.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #SplitFix (Tag, LotId, LotName)
    SELECT N'P_GP', NewId, MintedLotName FROM @cr;

-- P_OVER: parent at PieceCount=10 for the sum-exceeds-parent rejection.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 10, @AppUserId = 1;
INSERT INTO #SplitFix (Tag, LotId, LotName)
    SELECT N'P_OVER', NewId, MintedLotName FROM @cr;

-- P_99: parent at PieceCount=100 for the >99-sublots cap rejection.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #SplitFix (Tag, LotId, LotName)
    SELECT N'P_99', NewId, MintedLotName FROM @cr;
GO

-- =============================================
-- Test 1: 2-way split succeeds; Option-A return shape (2 child rows, Status=1);
--         child names are <parent>-01 / <parent>-02; parent reduced to 0 +
--         Closed; closure parent->child depth 1.
-- =============================================
DECLARE @ParentId   BIGINT = (SELECT LotId   FROM #SplitFix WHERE Tag = N'P_FULL');
DECLARE @ParentName NVARCHAR(50) = (SELECT LotName FROM #SplitFix WHERE Tag = N'P_FULL');
DECLARE @LocId BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @ParentId);

DECLARE @json NVARCHAR(MAX) =
    N'[{"pieceCount":25,"currentLocationId":' + CAST(@LocId AS NVARCHAR(20)) + N'},'
  + N'{"pieceCount":25,"currentLocationId":' + CAST(@LocId AS NVARCHAR(20)) + N'}]';

CREATE TABLE #s (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #s EXEC Lots.Lot_Split
    @ParentLotId = @ParentId, @ChildrenJson = @json, @AppUserId = 1;

-- Track the minted children for cleanup.
INSERT INTO #SplitFix (Tag, LotId, LotName)
    SELECT N'FULL_C' + CAST(ROW_NUMBER() OVER (ORDER BY ChildLotId) AS NVARCHAR(4)),
           ChildLotId, ChildLotName
    FROM #s WHERE ChildLotId IS NOT NULL;

DECLARE @ok1 BIT = (SELECT TOP 1 Status FROM #s);
EXEC test.Assert_IsTrue @TestName = N'[Split] 2-way split succeeds', @Condition = @ok1;

DECLARE @cnt1 INT = (SELECT COUNT(*) FROM #s);
EXEC test.Assert_RowCount @TestName = N'[Split] two child rows returned (Option A)',
    @ExpectedCount = 2, @ActualCount = @cnt1;

DECLARE @c01 INT = (SELECT COUNT(*) FROM #s WHERE ChildLotName = @ParentName + N'-01');
EXEC test.Assert_RowCount @TestName = N'[Split] child -01 name present',
    @ExpectedCount = 1, @ActualCount = @c01;
DECLARE @c02 INT = (SELECT COUNT(*) FROM #s WHERE ChildLotName = @ParentName + N'-02');
EXEC test.Assert_RowCount @TestName = N'[Split] child -02 name present',
    @ExpectedCount = 1, @ActualCount = @c02;

DECLARE @ppc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @ParentId);
DECLARE @ppcStr NVARCHAR(20) = CAST(@ppc AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Split] parent PieceCount reduced to 0',
    @Expected = N'0', @Actual = @ppcStr;

DECLARE @pStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @ParentId);
EXEC test.Assert_IsEqual @TestName = N'[Split] parent Closed at residual 0',
    @Expected = N'Closed', @Actual = @pStatus;

-- Closure: parent -> each child at depth 1.
DECLARE @child1 BIGINT = (SELECT MIN(ChildLotId) FROM #s);
DECLARE @d1 INT = (SELECT Depth FROM Lots.LotGenealogyClosure
                   WHERE AncestorLotId = @ParentId AND DescendantLotId = @child1);
DECLARE @d1Str NVARCHAR(20) = CAST(@d1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Split] closure parent->child depth 1',
    @Expected = N'1', @Actual = @d1Str;

-- LotGenealogy edge: one Split (RelationshipTypeId=1) edge per child.
DECLARE @edges INT = (SELECT COUNT(*) FROM Lots.LotGenealogy
                      WHERE ParentLotId = @ParentId AND RelationshipTypeId = 1);
EXEC test.Assert_RowCount @TestName = N'[Split] two Split genealogy edges recorded',
    @ExpectedCount = 2, @ActualCount = @edges;

DROP TABLE #s;
GO

-- =============================================
-- Test 2: 2-level tree -> closure grandparent->grandchild depth 2.
--   Grandparent (P_GP, 100) split off ONE child of 50 (the "mid" parent);
--   grandparent residual 50 (NOT closed). Then split mid into 2x25 -> mid
--   Closed; assert grandparent->grandchild closure depth = 2.
-- =============================================
DECLARE @GpId   BIGINT = (SELECT LotId   FROM #SplitFix WHERE Tag = N'P_GP');
DECLARE @GpName NVARCHAR(50) = (SELECT LotName FROM #SplitFix WHERE Tag = N'P_GP');
DECLARE @GpLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @GpId);

-- Split grandparent -> single mid child of 50.
DECLARE @jsonMid NVARCHAR(MAX) =
    N'[{"pieceCount":50,"currentLocationId":' + CAST(@GpLoc AS NVARCHAR(20)) + N'}]';
CREATE TABLE #mid (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #mid EXEC Lots.Lot_Split
    @ParentLotId = @GpId, @ChildrenJson = @jsonMid, @AppUserId = 1;

DECLARE @MidId   BIGINT = (SELECT TOP 1 ChildLotId   FROM #mid);
DECLARE @MidName NVARCHAR(50) = (SELECT TOP 1 ChildLotName FROM #mid);
INSERT INTO #SplitFix (Tag, LotId, LotName) VALUES (N'GP_MID', @MidId, @MidName);

-- Grandparent should still be open (residual 50, not 0).
DECLARE @gpStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @GpId);
EXEC test.Assert_IsEqual @TestName = N'[Split] grandparent stays Good at residual 50',
    @Expected = N'Good', @Actual = @gpStatus;

-- Mid name is <grandparent>-01.
DECLARE @MidExpected NVARCHAR(50) = @GpName + N'-01';
EXEC test.Assert_IsEqual @TestName = N'[Split] mid child name is <gp>-01',
    @Expected = @MidExpected, @Actual = @MidName;

-- Now split mid -> 2x25 -> grandchildren.
DECLARE @jsonGc NVARCHAR(MAX) =
    N'[{"pieceCount":25,"currentLocationId":' + CAST(@GpLoc AS NVARCHAR(20)) + N'},'
  + N'{"pieceCount":25,"currentLocationId":' + CAST(@GpLoc AS NVARCHAR(20)) + N'}]';
CREATE TABLE #gc (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #gc EXEC Lots.Lot_Split
    @ParentLotId = @MidId, @ChildrenJson = @jsonGc, @AppUserId = 1;

INSERT INTO #SplitFix (Tag, LotId, LotName)
    SELECT N'GP_GC' + CAST(ROW_NUMBER() OVER (ORDER BY ChildLotId) AS NVARCHAR(4)),
           ChildLotId, ChildLotName
    FROM #gc WHERE ChildLotId IS NOT NULL;

DECLARE @GcId   BIGINT = (SELECT MIN(ChildLotId)  FROM #gc);
DECLARE @GcName NVARCHAR(50) = (SELECT ChildLotName FROM #gc WHERE ChildLotId = @GcId);

-- Re-split appends a SECOND suffix: grandchild name ends '-01-01' (mid is <gp>-01).
DECLARE @GcExpected NVARCHAR(50) = @GpName + N'-01-01';
EXEC test.Assert_IsEqual @TestName = N'[Split] re-split grandchild name ends -01-01',
    @Expected = @GcExpected, @Actual = @GcName;

-- Closure depth: grandparent -> grandchild = 2; mid -> grandchild = 1.
DECLARE @d2 INT = (SELECT Depth FROM Lots.LotGenealogyClosure
                   WHERE AncestorLotId = @GpId AND DescendantLotId = @GcId);
DECLARE @d2Str NVARCHAR(20) = CAST(@d2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Split] closure grandparent->grandchild depth 2',
    @Expected = N'2', @Actual = @d2Str;

DECLARE @d1b INT = (SELECT Depth FROM Lots.LotGenealogyClosure
                    WHERE AncestorLotId = @MidId AND DescendantLotId = @GcId);
DECLARE @d1bStr NVARCHAR(20) = CAST(@d1b AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Split] closure mid->grandchild depth 1',
    @Expected = N'1', @Actual = @d1bStr;

DROP TABLE #mid;
DROP TABLE #gc;
GO

-- =============================================
-- Test 3: SUM(children) > parent.PieceCount rejected -> single error row,
--         Status=0, NULL child columns; no children minted.
-- =============================================
DECLARE @OverId BIGINT = (SELECT LotId FROM #SplitFix WHERE Tag = N'P_OVER');
DECLARE @OverLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @OverId);

DECLARE @jsonOver NVARCHAR(MAX) =
    N'[{"pieceCount":6,"currentLocationId":' + CAST(@OverLoc AS NVARCHAR(20)) + N'},'
  + N'{"pieceCount":6,"currentLocationId":' + CAST(@OverLoc AS NVARCHAR(20)) + N'}]';
CREATE TABLE #over (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #over EXEC Lots.Lot_Split
    @ParentLotId = @OverId, @ChildrenJson = @jsonOver, @AppUserId = 1;

DECLARE @ovStatus BIT = (SELECT TOP 1 Status FROM #over);
DECLARE @ovCond BIT = CASE WHEN @ovStatus = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Split] sum-exceeds-parent rejected (Status=0)', @Condition = @ovCond;

DECLARE @ovRows INT = (SELECT COUNT(*) FROM #over);
EXEC test.Assert_RowCount @TestName = N'[Split] error exit returns a single row',
    @ExpectedCount = 1, @ActualCount = @ovRows;

DECLARE @ovChild BIGINT = (SELECT TOP 1 ChildLotId FROM #over);
DECLARE @ovChildStr NVARCHAR(20) = CAST(@ovChild AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[Split] error row ChildLotId is NULL',
    @Value = @ovChildStr;

-- No children actually minted under the rejected parent.
DECLARE @ovMinted INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ParentLotId = @OverId);
EXEC test.Assert_RowCount @TestName = N'[Split] no children minted on rejection',
    @ExpectedCount = 0, @ActualCount = @ovMinted;

DECLARE @ovPc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @OverId);
DECLARE @ovPcStr NVARCHAR(20) = CAST(@ovPc AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Split] parent PieceCount unchanged on rejection',
    @Expected = N'10', @Actual = @ovPcStr;

DROP TABLE #over;
GO

-- =============================================
-- Test 4: >99 sublots rejected. SHORTCUT: directly seed a child row named
--         '<parent>-99' under P_99 (a real LOT row whose LotName matches the
--         '-NN' suffix probe) so the next ordinal computes to 100; the split
--         then rejects before minting. This avoids creating 99 real children.
-- =============================================
DECLARE @P99   BIGINT = (SELECT LotId   FROM #SplitFix WHERE Tag = N'P_99');
DECLARE @P99Name NVARCHAR(50) = (SELECT LotName FROM #SplitFix WHERE Tag = N'P_99');
DECLARE @P99Loc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @P99);

-- Seed a stub child LOT named '<parent>-99' (Good, ItemId/Origin inherited).
DECLARE @stItem BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @P99);
DECLARE @stOrigin BIGINT = (SELECT LotOriginTypeId FROM Lots.Lot WHERE Id = @P99);
DECLARE @stGood BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
-- Stub child: only LotName + ParentLotId are needed to drive the ordinal probe to 100.
-- LotStatusHistory / self-closure side-effects are intentionally omitted -- this parent
-- is rejected at validation and never reaches the mutation path.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
    ParentLotId, CurrentLocationId, TotalInProcess, InventoryAvailable,
    CreatedByUserId, CreatedAt)
VALUES (@P99Name + N'-99', @stItem, @stOrigin, @stGood, 1,
    @P99, @P99Loc, 0, 1, 1, SYSUTCDATETIME());
INSERT INTO #SplitFix (Tag, LotId, LotName)
    VALUES (N'P99_STUB', SCOPE_IDENTITY(), @P99Name + N'-99');

DECLARE @json99 NVARCHAR(MAX) =
    N'[{"pieceCount":5,"currentLocationId":' + CAST(@P99Loc AS NVARCHAR(20)) + N'}]';
CREATE TABLE #c99 (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #c99 EXEC Lots.Lot_Split
    @ParentLotId = @P99, @ChildrenJson = @json99, @AppUserId = 1;

DECLARE @s99 BIT = (SELECT TOP 1 Status FROM #c99);
DECLARE @s99Cond BIT = CASE WHEN @s99 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Split] >99 sublots rejected (Status=0)', @Condition = @s99Cond;

DECLARE @m99 NVARCHAR(500) = (SELECT TOP 1 Message FROM #c99);
EXEC test.Assert_Contains @TestName = N'[Split] >99 reject message mentions 99',
    @HaystackStr = @m99, @NeedleStr = N'99';

DROP TABLE #c99;
GO

-- ---- cleanup (FK-safe: child rows -> LOTs; descendants before ancestors) ----
-- Audit.OperationLog / Lots.LotEventLog attribute to AppUser and carry no FK to
-- Lots.Lot, but LotEventLog rows are deleted here per feedback_runtests_exit1
-- (audit children before AppUser). Delete genealogy/closure first (FK to Lot),
-- then movement/status/attribute, then the LOTs. LOTs are deleted in an order
-- that respects the self-referencing ParentLotId FK: children (have ParentLotId)
-- before parents -- a single DELETE over the id set works because we also clear
-- ParentLotId references via deleting all rows together is NOT safe, so null the
-- ParentLotId pointers first.
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #SplitFix WHERE LotId IS NOT NULL;

DELETE FROM Lots.LotGenealogy
    WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure
    WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);

-- Break the self-referencing ParentLotId FK before deleting the LOT rows.
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#SplitFix') IS NOT NULL DROP TABLE #SplitFix;
GO

EXEC test.EndTestFile;
GO
