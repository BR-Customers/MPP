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
