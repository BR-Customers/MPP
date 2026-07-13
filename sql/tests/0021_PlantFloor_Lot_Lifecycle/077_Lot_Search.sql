SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/077_Lot_Search.sql';
GO
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO
DECLARE @OriginRcv BIGINT=(SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT;
SELECT TOP 1 @ItemId=eil.ItemId, @CellA=eil.LocationId FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL) ORDER BY eil.LocationId;
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
DECLARE @hitStr NVARCHAR(10)=CAST(@hit AS NVARCHAR(10));
DROP TABLE #r1;
EXEC test.Assert_IsEqual @TestName=N'[Search] vendor-LOT fragment matches', @Expected=N'1', @Actual=@hitStr;
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
