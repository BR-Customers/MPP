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

-- Diamond fixture: DA (top) produces into BOTH DB and DC (two middles), which both
-- produce into DD (bottom convergence). DD is multi-parent; DA is a shared ancestor
-- reachable via two distinct paths (DA->DB->DD and DA->DC->DD).
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=1000, @AppUserId=1;
INSERT INTO #Fix SELECT N'DA', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=200, @AppUserId=1;
INSERT INTO #Fix SELECT N'DB', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=200, @AppUserId=1;
INSERT INTO #Fix SELECT N'DC', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=50, @AppUserId=1;
INSERT INTO #Fix SELECT N'DD', NewId, MintedLotName FROM @cr;

DECLARE @DA BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DA');
DECLARE @DB BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DB');
DECLARE @DC BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DC');
DECLARE @DD BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DD');

DELETE FROM @rc;
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@DA, @ConsumedPieceCount=10, @ProducedLotId=@DB, @AppUserId=1;
DELETE FROM @rc;
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@DA, @ConsumedPieceCount=12, @ProducedLotId=@DC, @AppUserId=1;
DELETE FROM @rc;
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@DB, @ConsumedPieceCount=5, @ProducedLotId=@DD, @AppUserId=1;
DELETE FROM @rc;
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@DC, @ConsumedPieceCount=7, @ProducedLotId=@DD, @AppUserId=1;
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

-- Real resolution check (not just non-null): the fixture item's actual preferred UOM
-- code must be the one surfaced on a known ancestor row. (@ItemId is scoped to the
-- fixture batch, so resolve it fresh here via the row's own ItemId column.)
DECLARE @ancItemId BIGINT = (SELECT ItemId FROM #anc WHERE RelatedLotId=@A);
DECLARE @realUom NVARCHAR(20) = (SELECT u.Code FROM Parts.Uom u
    INNER JOIN Parts.Item i ON i.UomId=u.Id WHERE i.Id=@ancItemId);
DECLARE @aUom NVARCHAR(20) = (SELECT UomCode FROM #anc WHERE RelatedLotId=@A);
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] UomCode resolves to the item preferred UOM',
    @Expected=@realUom, @Actual=@aUom;

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

-- Test 4: diamond / multi-path convergence. DD's ancestors reach DA via two
-- distinct paths (DA->DB->DD and DA->DC->DD), so DA MUST be emitted twice, not
-- once -- proving emission is per DISTINCT PATH, not per node.
DECLARE @DA BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DA');
DECLARE @DB BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DB');
DECLARE @DC BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DC');
DECLARE @DD BIGINT=(SELECT LotId FROM #Fix WHERE Tag=N'DD');

IF OBJECT_ID(N'tempdb..#dd') IS NOT NULL DROP TABLE #dd;
CREATE TABLE #dd (RelatedLotId BIGINT, RelatedLotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50),
                  RelationshipName NVARCHAR(100), PieceCount INT, UomCode NVARCHAR(20), Depth INT, Direction NVARCHAR(20));
INSERT INTO #dd EXEC Lots.Lot_GetGenealogyEdgeTree @LotId=@DD, @Direction=N'Ancestors';

DECLARE @daRows INT = (SELECT COUNT(*) FROM #dd WHERE RelatedLotId=@DA);
DECLARE @daRowsStr NVARCHAR(20) = CAST(@daRows AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] diamond: shared ancestor DA emitted once per path (2)',
    @Expected=N'2', @Actual=@daRowsStr;

DECLARE @dbRows INT = (SELECT COUNT(*) FROM #dd WHERE RelatedLotId=@DB);
DECLARE @dbRowsStr NVARCHAR(20) = CAST(@dbRows AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] diamond: DB appears once at Depth 1',
    @Expected=N'1', @Actual=@dbRowsStr;
DECLARE @dcRows INT = (SELECT COUNT(*) FROM #dd WHERE RelatedLotId=@DC);
DECLARE @dcRowsStr NVARCHAR(20) = CAST(@dcRows AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] diamond: DC appears once at Depth 1',
    @Expected=N'1', @Actual=@dcRowsStr;

DECLARE @dbDepth NVARCHAR(20) = (SELECT CAST(Depth AS NVARCHAR(20)) FROM #dd WHERE RelatedLotId=@DB);
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] diamond: DB at Depth 1', @Expected=N'1', @Actual=@dbDepth;
DECLARE @dcDepth NVARCHAR(20) = (SELECT CAST(Depth AS NVARCHAR(20)) FROM #dd WHERE RelatedLotId=@DC);
EXEC test.Assert_IsEqual @TestName=N'[EdgeTree] diamond: DC at Depth 1', @Expected=N'1', @Actual=@dcDepth;

DECLARE @daDepthsOk BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM #dd WHERE RelatedLotId=@DA AND Depth<>2) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[EdgeTree] diamond: both DA rows at Depth 2', @Condition=@daDepthsOk;
DROP TABLE #dd;
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
