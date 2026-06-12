-- =============================================
-- File:         0020_PlantFloor_Foundation/050_Lot_Get_List.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Lots.Lot_Get and Lots.Lot_List.
--                 - Lot_Get by Id returns the row + materialized quantities
--                 - Lot_Get by LotName returns the row
--                 - Lot_Get of a non-existent id -> empty result set
--                 - Lot_List filters by ItemId / LotStatusId
--                 - Lot_List @LimitRows caps the rowset
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/050_Lot_Get_List.sql';
GO

-- ---- fixture: two lots via Lot_Create on a no-tool eligible cell ----
DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

CREATE TABLE #mk (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #mk EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=11, @AppUserId=1;
INSERT INTO #mk EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=22, @AppUserId=1;
DROP TABLE #mk;
GO

-- =============================================
-- Test 1: Lot_Get by Id returns the row with materialized quantities
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @InvAvail INT, @InvStr NVARCHAR(10), @PieceCount INT, @PieceStr NVARCHAR(10);
CREATE TABLE #g (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, Weight DECIMAL(12,4), WeightUomId BIGINT, ToolId BIGINT, ToolCavityId BIGINT,
    VendorLotNumber NVARCHAR(100), MinSerialNumber INT, MaxSerialNumber INT, ParentLotId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT, CreatedByUserId BIGINT, CreatedAtTerminalId BIGINT,
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), UpdatedByUserId BIGINT, RowVersion BINARY(8),
    ItemPartNumber NVARCHAR(50), LotOriginTypeCode NVARCHAR(30), LotStatusCode NVARCHAR(20), LotStatusName NVARCHAR(100), CurrentLocationName NVARCHAR(200),
    ToolCode NVARCHAR(50), ToolCavityNumber NVARCHAR(20));
INSERT INTO #g EXEC Lots.Lot_Get @LotId = @LotId;
SELECT @InvAvail = InventoryAvailable, @PieceCount = PieceCount FROM #g;
DROP TABLE #g;
SET @InvStr = CAST(@InvAvail AS NVARCHAR(10));
SET @PieceStr = CAST(@PieceCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LotGetById] InventoryAvailable equals PieceCount', @Expected = @PieceStr, @Actual = @InvStr;
GO

-- =============================================
-- Test 2: Lot_Get by LotName returns exactly one row
-- =============================================
DECLARE @Name NVARCHAR(50) = (SELECT TOP 1 LotName FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Cnt INT, @CntStr NVARCHAR(10);
CREATE TABLE #g2 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, Weight DECIMAL(12,4), WeightUomId BIGINT, ToolId BIGINT, ToolCavityId BIGINT,
    VendorLotNumber NVARCHAR(100), MinSerialNumber INT, MaxSerialNumber INT, ParentLotId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT, CreatedByUserId BIGINT, CreatedAtTerminalId BIGINT,
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), UpdatedByUserId BIGINT, RowVersion BINARY(8),
    ItemPartNumber NVARCHAR(50), LotOriginTypeCode NVARCHAR(30), LotStatusCode NVARCHAR(20), LotStatusName NVARCHAR(100), CurrentLocationName NVARCHAR(200),
    ToolCode NVARCHAR(50), ToolCavityNumber NVARCHAR(20));
INSERT INTO #g2 EXEC Lots.Lot_Get @LotName = @Name;
SELECT @Cnt = COUNT(*) FROM #g2;
DROP TABLE #g2;
SET @CntStr = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LotGetByName] Exactly one row', @Expected = N'1', @Actual = @CntStr;
GO

-- =============================================
-- Test 3: Lot_Get non-existent id -> empty result set
-- =============================================
DECLARE @Cnt INT, @CntStr NVARCHAR(10);
CREATE TABLE #g3 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, Weight DECIMAL(12,4), WeightUomId BIGINT, ToolId BIGINT, ToolCavityId BIGINT,
    VendorLotNumber NVARCHAR(100), MinSerialNumber INT, MaxSerialNumber INT, ParentLotId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT, CreatedByUserId BIGINT, CreatedAtTerminalId BIGINT,
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), UpdatedByUserId BIGINT, RowVersion BINARY(8),
    ItemPartNumber NVARCHAR(50), LotOriginTypeCode NVARCHAR(30), LotStatusCode NVARCHAR(20), LotStatusName NVARCHAR(100), CurrentLocationName NVARCHAR(200),
    ToolCode NVARCHAR(50), ToolCavityNumber NVARCHAR(20));
INSERT INTO #g3 EXEC Lots.Lot_Get @LotId = 9999999999;
SELECT @Cnt = COUNT(*) FROM #g3;
DROP TABLE #g3;
SET @CntStr = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LotGetMissing] Empty result set', @Expected = N'0', @Actual = @CntStr;
GO

-- =============================================
-- Test 4: Lot_List filters by ItemId (>= our 2 fixture lots)
-- =============================================
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Cnt INT, @CntStr NVARCHAR(10);
CREATE TABLE #l (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, ToolId BIGINT, ToolCavityId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT, CreatedAt DATETIME2(3),
    ItemPartNumber NVARCHAR(50), LotStatusCode NVARCHAR(20), CurrentLocationName NVARCHAR(200), TotalCount BIGINT);
INSERT INTO #l EXEC Lots.Lot_List @ItemId = @ItemId;
SELECT @Cnt = COUNT(*) FROM #l WHERE LotName LIKE N'MESL%';
DROP TABLE #l;
DECLARE @AtLeast2 NVARCHAR(1) = CASE WHEN @Cnt >= 2 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LotListByItem] Returns the >=2 fixture lots', @Expected = N'1', @Actual = @AtLeast2;
GO

-- =============================================
-- Test 5: Lot_List @LimitRows caps the rowset
-- =============================================
DECLARE @Cnt INT, @CntStr NVARCHAR(10);
CREATE TABLE #l2 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT, LotStatusId BIGINT,
    PieceCount INT, MaxPieceCount INT, ToolId BIGINT, ToolCavityId BIGINT, CurrentLocationId BIGINT,
    CrtActive BIT, TotalInProcess INT, InventoryAvailable INT, CreatedAt DATETIME2(3),
    ItemPartNumber NVARCHAR(50), LotStatusCode NVARCHAR(20), CurrentLocationName NVARCHAR(200), TotalCount BIGINT);
INSERT INTO #l2 EXEC Lots.Lot_List @LimitRows = 1;
SELECT @Cnt = COUNT(*) FROM #l2;
DROP TABLE #l2;
SET @CntStr = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LotListLimit] LimitRows=1 returns at most 1', @Expected = N'1', @Actual = @CntStr;
GO

-- ---- cleanup ----
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
