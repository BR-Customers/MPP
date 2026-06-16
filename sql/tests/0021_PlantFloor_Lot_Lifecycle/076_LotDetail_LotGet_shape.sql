SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/076_LotDetail_LotGet_shape.sql';
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
