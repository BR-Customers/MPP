-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/040_LotGenealogy_RecordConsumption.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for Lots.LotGenealogy_RecordConsumption (Phase 2 Task 4 / G2;
--               spec section 4.2). Asserts the single-row Status/Message/NewId
--               return; that a consumption edge (RelationshipTypeId=3) is recorded
--               from a source LOT into a produced LOT with the consumed PieceCount;
--               the B4 closure single-edge insert ((source, produced) at depth 1 and
--               every ancestor of source -> produced at depth+1); multi-source
--               consumption into the SAME produced LOT (two edges, both ancestor
--               sets in closure); and the rejection paths (NULL @ProducedLotId,
--               zero/negative @ConsumedPieceCount, blocked source).
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so Lot_Create
--               needs no Tool/Cavity. A 2-level ancestor case is built via Lot_Split
--               (grandparent -> source) to assert depth-2 closure propagation.
--               Every fixture LOT id is tracked in #ConsFix for FK-safe teardown.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/040_LotGenealogy_RecordConsumption.sql';
GO

-- ---- shared fixtures ----
IF OBJECT_ID(N'tempdb..#ConsFix') IS NOT NULL DROP TABLE #ConsFix;
CREATE TABLE #ConsFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- SRC1, PROD1: simple LOT-to-LOT consumption pair.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 50, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'SRC1', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 10, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'PROD1', NewId, MintedLotName FROM @cr;

-- GP -> SRC2 (via split): SRC2 has GP as a depth-1 ancestor. PROD2 is the produced
-- LOT. Consuming SRC2 into PROD2 should propagate GP -> PROD2 at depth 2.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 40, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'GP', NewId, MintedLotName FROM @cr;

DECLARE @GpId BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'GP');
DECLARE @CellGp BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @GpId);
DECLARE @jsonSplit NVARCHAR(MAX) =
    N'[{"pieceCount":40,"currentLocationId":' + CAST(@CellGp AS NVARCHAR(20)) + N'}]';
IF OBJECT_ID(N'tempdb..#sp') IS NOT NULL DROP TABLE #sp;
CREATE TABLE #sp (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #sp EXEC Lots.Lot_Split
    @ParentLotId = @GpId, @ChildrenJson = @jsonSplit, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName)
    SELECT N'SRC2', ChildLotId, ChildLotName FROM #sp WHERE ChildLotId IS NOT NULL;
DROP TABLE #sp;

DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 5, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'PROD2', NewId, MintedLotName FROM @cr;

-- SRC3A, SRC3B: two distinct sources consumed into the SAME produced LOT PROD3.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 20, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'SRC3A', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 30, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'SRC3B', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 8, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'PROD3', NewId, MintedLotName FROM @cr;

-- SRC4, PROD4: blocked-source rejection pair (SRC4 forced to Hold).
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 15, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'SRC4', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 4, @AppUserId = 1;
INSERT INTO #ConsFix (Tag, LotId, LotName) SELECT N'PROD4', NewId, MintedLotName FROM @cr;

UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold')
WHERE Id = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC4');
GO

-- =============================================
-- Test 1: LOT-to-LOT consumption edge recorded. Status=1; NewId returned; exactly
--         one LotGenealogy Consumption row (RelationshipTypeId=3) with the right
--         Parent/Child/PieceCount.
-- =============================================
DECLARE @Src1 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC1');
DECLARE @Prod1 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'PROD1');

DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r1 EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @Src1, @ConsumedPieceCount = 25, @ProducedLotId = @Prod1, @AppUserId = 1;

DECLARE @ok1 BIT = (SELECT Status FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[Consume] LOT-to-LOT consumption succeeds', @Condition = @ok1;

DECLARE @ni1 NVARCHAR(20) = CAST((SELECT NewId FROM @r1) AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[Consume] NewId returned (LotGenealogy.Id)', @Value = @ni1;

DECLARE @edges1 INT = (SELECT COUNT(*) FROM Lots.LotGenealogy
                       WHERE ParentLotId = @Src1 AND ChildLotId = @Prod1 AND RelationshipTypeId = 3);
EXEC test.Assert_RowCount @TestName = N'[Consume] one Consumption edge (RelationshipTypeId=3)',
    @ExpectedCount = 1, @ActualCount = @edges1;

DECLARE @pc1 NVARCHAR(20) = CAST((SELECT PieceCount FROM Lots.LotGenealogy
                                  WHERE ParentLotId = @Src1 AND ChildLotId = @Prod1 AND RelationshipTypeId = 3) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Consume] edge PieceCount = consumed (25)',
    @Expected = N'25', @Actual = @pc1;

-- NewId from the proc equals the inserted edge row's Id.
DECLARE @edgeId BIGINT = (SELECT Id FROM Lots.LotGenealogy
                          WHERE ParentLotId = @Src1 AND ChildLotId = @Prod1 AND RelationshipTypeId = 3);
DECLARE @niMatch BIT = CASE WHEN (SELECT NewId FROM @r1) = @edgeId THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Consume] NewId = inserted edge Id', @Condition = @niMatch;
GO

-- =============================================
-- Test 2: closure rows inserted. (source, produced) at depth 1; and -- because
--         SRC2 has GP as a depth-1 ancestor -- (GP, produced) at depth 2.
-- =============================================
DECLARE @Src2 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC2');
DECLARE @Prod2 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'PROD2');
DECLARE @Gp BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'GP');

DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r2 EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @Src2, @ConsumedPieceCount = 12, @ProducedLotId = @Prod2, @AppUserId = 1;

DECLARE @ok2 BIT = (SELECT Status FROM @r2);
EXEC test.Assert_IsTrue @TestName = N'[Consume] ancestor-chain consumption succeeds', @Condition = @ok2;

-- (source, produced) closure depth 1.
DECLARE @cd1 INT = (SELECT Depth FROM Lots.LotGenealogyClosure
                    WHERE AncestorLotId = @Src2 AND DescendantLotId = @Prod2);
DECLARE @cd1Str NVARCHAR(20) = CAST(@cd1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Consume] source->produced closure depth 1',
    @Expected = N'1', @Actual = @cd1Str;

-- (grandparent, produced) closure depth 2 (GP->SRC2 depth1, +1 = depth 2).
DECLARE @cd2 INT = (SELECT Depth FROM Lots.LotGenealogyClosure
                    WHERE AncestorLotId = @Gp AND DescendantLotId = @Prod2);
DECLARE @cd2Str NVARCHAR(20) = CAST(@cd2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Consume] grandparent->produced closure depth 2',
    @Expected = N'2', @Actual = @cd2Str;
GO

-- =============================================
-- Test 3: multi-source consumption into ONE produced LOT. Two separate calls
--         (SRC3A, SRC3B) -> PROD3. Assert two Consumption edges + both ancestor
--         (self-row) sets present in closure for PROD3.
-- =============================================
DECLARE @S3A BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC3A');
DECLARE @S3B BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC3B');
DECLARE @Prod3 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'PROD3');

DECLARE @r3a TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3a EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @S3A, @ConsumedPieceCount = 10, @ProducedLotId = @Prod3, @AppUserId = 1;
DECLARE @ok3a BIT = (SELECT Status FROM @r3a);
EXEC test.Assert_IsTrue @TestName = N'[Consume] first source into shared produced succeeds', @Condition = @ok3a;

DECLARE @r3b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3b EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @S3B, @ConsumedPieceCount = 15, @ProducedLotId = @Prod3, @AppUserId = 1;
DECLARE @ok3b BIT = (SELECT Status FROM @r3b);
EXEC test.Assert_IsTrue @TestName = N'[Consume] second source into shared produced succeeds', @Condition = @ok3b;

-- Two Consumption edges into PROD3.
DECLARE @edges3 INT = (SELECT COUNT(*) FROM Lots.LotGenealogy
                       WHERE ChildLotId = @Prod3 AND RelationshipTypeId = 3);
EXEC test.Assert_RowCount @TestName = N'[Consume] two Consumption edges into shared produced',
    @ExpectedCount = 2, @ActualCount = @edges3;

-- Both source self-rows are ancestors of PROD3 at depth 1.
DECLARE @anc3 INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure
                     WHERE DescendantLotId = @Prod3 AND AncestorLotId IN (@S3A, @S3B) AND Depth = 1);
EXEC test.Assert_RowCount @TestName = N'[Consume] both sources are depth-1 ancestors of produced',
    @ExpectedCount = 2, @ActualCount = @anc3;
GO

-- =============================================
-- Test 4: missing produced LOT rejected (@ProducedLotId = NULL -> Status=0).
-- =============================================
DECLARE @S3A_b BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC3A');

DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4 EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @S3A_b, @ConsumedPieceCount = 3, @ProducedLotId = NULL, @AppUserId = 1;

DECLARE @s4 BIT = (SELECT Status FROM @r4);
DECLARE @s4Cond BIT = CASE WHEN @s4 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Consume] NULL ProducedLotId rejected (Status=0)', @Condition = @s4Cond;

DECLARE @ni4 NVARCHAR(20) = CAST((SELECT NewId FROM @r4) AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[Consume] rejected call returns NULL NewId', @Value = @ni4;
GO

-- =============================================
-- Test 5: zero / negative piece count rejected.
-- =============================================
DECLARE @S3A_c BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC3A');
DECLARE @Prod3_c BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'PROD3');

DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5 EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @S3A_c, @ConsumedPieceCount = 0, @ProducedLotId = @Prod3_c, @AppUserId = 1;
DECLARE @s5 BIT = (SELECT Status FROM @r5);
DECLARE @s5Cond BIT = CASE WHEN @s5 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Consume] zero piece count rejected (Status=0)', @Condition = @s5Cond;

DECLARE @r5b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5b EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @S3A_c, @ConsumedPieceCount = -5, @ProducedLotId = @Prod3_c, @AppUserId = 1;
DECLARE @s5b BIT = (SELECT Status FROM @r5b);
DECLARE @s5bCond BIT = CASE WHEN @s5b = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Consume] negative piece count rejected (Status=0)', @Condition = @s5bCond;
GO

-- =============================================
-- Test 6: blocked source rejected (SRC4 is Hold).
-- =============================================
DECLARE @Src4 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'SRC4');
DECLARE @Prod4 BIGINT = (SELECT LotId FROM #ConsFix WHERE Tag = N'PROD4');

DECLARE @r6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r6 EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId = @Src4, @ConsumedPieceCount = 5, @ProducedLotId = @Prod4, @AppUserId = 1;
DECLARE @s6 BIT = (SELECT Status FROM @r6);
DECLARE @s6Cond BIT = CASE WHEN @s6 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Consume] blocked (Hold) source rejected (Status=0)', @Condition = @s6Cond;

-- No edge recorded for the rejected blocked-source call.
DECLARE @edges6 INT = (SELECT COUNT(*) FROM Lots.LotGenealogy
                       WHERE ParentLotId = @Src4 AND ChildLotId = @Prod4);
EXEC test.Assert_RowCount @TestName = N'[Consume] no edge recorded for blocked source',
    @ExpectedCount = 0, @ActualCount = @edges6;
GO

-- ---- cleanup (FK-safe: child rows -> LOTs; descendants before ancestors) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #ConsFix WHERE LotId IS NOT NULL;

DELETE FROM Lots.LotGenealogy
    WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure
    WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);

-- Break self-referencing ParentLotId FK before deleting LOT rows.
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#ConsFix') IS NOT NULL DROP TABLE #ConsFix;
GO

EXEC test.EndTestFile;
GO
