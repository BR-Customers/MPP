-- =============================================
-- File:         0019_Parts_ConsumptionMetadata_And_ScrapSource/010_Phase_E_additives.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-23
-- Description:
--   Tests for the Phase E additive schema changes delivered in G.1/G.3
--   plus the 0013 corrections:
--     Parts.Item.CountryOfOrigin (OI-19)
--     Parts.ItemLocation consumption metadata (OI-18)
--     Parts.ItemLocation_SetConsumptionMetadata
--     Workorder.WorkOrderType_List (single Production seed, post-OI-07)
--     Workorder.ScrapSource_List (2 seed rows, OI-20)
--
--   MaxParts coverage moved to 0008_Parts_Item/010_Item_crud.sql after
--   the OI-12 correction relocated MaxParts from Parts.ContainerConfig
--   to Parts.Item.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0019_Parts_ConsumptionMetadata_And_ScrapSource/010_Phase_E_additives.sql';
GO

-- =============================================
-- Setup: create an Item with CountryOfOrigin
-- =============================================
DECLARE @ItemTypeId BIGINT = (SELECT TOP 1 Id FROM Parts.ItemType WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @UomId BIGINT = (SELECT TOP 1 Id FROM Parts.Uom WHERE DeprecatedAt IS NULL ORDER BY Id);

CREATE TABLE #IC (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #IC EXEC Parts.Item_Create
    @PartNumber = N'PH-E-TEST-001', @ItemTypeId = @ItemTypeId,
    @Description = N'Phase E test part',
    @UomId = @UomId,
    @CountryOfOrigin = N'US',
    @AppUserId = 1;
DROP TABLE #IC;
GO

-- =============================================
-- Test 1: Item_Create stored CountryOfOrigin
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PH-E-TEST-001');
DECLARE @CoO NVARCHAR(2);
SELECT @CoO = CountryOfOrigin FROM Parts.Item WHERE Id = @ItemId;

EXEC test.Assert_IsEqual
    @TestName = N'[Item CountryOfOrigin] stored as US',
    @Expected = N'US', @Actual = @CoO;
GO

-- =============================================
-- Test 2: Item_Update changes CountryOfOrigin
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PH-E-TEST-001');
DECLARE @UomId BIGINT = (SELECT UomId FROM Parts.Item WHERE Id = @ItemId);

CREATE TABLE #IU (Status BIT, Message NVARCHAR(500));
INSERT INTO #IU EXEC Parts.Item_Update
    @Id = @ItemId, @UomId = @UomId,
    @CountryOfOrigin = N'MX', @AppUserId = 1;
DROP TABLE #IU;

DECLARE @CoO NVARCHAR(2);
SELECT @CoO = CountryOfOrigin FROM Parts.Item WHERE Id = @ItemId;
EXEC test.Assert_IsEqual
    @TestName = N'[Item CountryOfOrigin] updated to MX',
    @Expected = N'MX', @Actual = @CoO;
GO

-- =============================================
-- Tests 3 + 4 (ContainerConfig MaxParts) removed: OI-12 correction
-- (migration 0013) relocated MaxParts from Parts.ContainerConfig to
-- Parts.Item. Equivalent coverage now lives in
-- 0008_Parts_Item/010_Item_crud.sql.
-- =============================================

-- =============================================
-- Test 5: ItemLocation_Add writes consumption metadata on INSERT
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PH-E-TEST-001');
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');

CREATE TABLE #ILA (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ILA EXEC Parts.ItemLocation_Add
    @ItemId = @ItemId, @LocationId = @LocId,
    @MinQuantity = 10, @MaxQuantity = 100, @DefaultQuantity = 50,
    @IsConsumptionPoint = 1, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #ILA);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @IlId BIGINT = (SELECT NewId FROM #ILA);
DROP TABLE #ILA;

EXEC test.Assert_IsEqual
    @TestName = N'[ItemLocation_Add w/ metadata] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @Min INT, @Max INT, @Dflt INT, @IsCP BIT;
SELECT @Min = MinQuantity, @Max = MaxQuantity,
       @Dflt = DefaultQuantity, @IsCP = IsConsumptionPoint
FROM Parts.ItemLocation WHERE Id = @IlId;

DECLARE @MinStr NVARCHAR(10) = CAST(@Min AS NVARCHAR(10));
DECLARE @MaxStr NVARCHAR(10) = CAST(@Max AS NVARCHAR(10));
DECLARE @DfltStr NVARCHAR(10) = CAST(@Dflt AS NVARCHAR(10));
DECLARE @CPStr NVARCHAR(1) = CAST(@IsCP AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[ItemLocation_Add] MinQuantity = 10',
    @Expected = N'10', @Actual = @MinStr;
EXEC test.Assert_IsEqual
    @TestName = N'[ItemLocation_Add] MaxQuantity = 100',
    @Expected = N'100', @Actual = @MaxStr;
EXEC test.Assert_IsEqual
    @TestName = N'[ItemLocation_Add] IsConsumptionPoint = 1',
    @Expected = N'1', @Actual = @CPStr;
GO

-- =============================================
-- Test 6: ItemLocation_Add rejects Min > Max
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PH-E-TEST-001');
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-402');

CREATE TABLE #ILBad (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ILBad EXEC Parts.ItemLocation_Add
    @ItemId = @ItemId, @LocationId = @LocId,
    @MinQuantity = 100, @MaxQuantity = 10,
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #ILBad);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #ILBad;

EXEC test.Assert_IsEqual
    @TestName = N'[ItemLocation_Add Min>Max] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 7: SetConsumptionMetadata changes values on existing row
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PH-E-TEST-001');
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');
DECLARE @IlId BIGINT = (
    SELECT Id FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @LocId AND DeprecatedAt IS NULL);

CREATE TABLE #SM (Status BIT, Message NVARCHAR(500));
INSERT INTO #SM EXEC Parts.ItemLocation_SetConsumptionMetadata
    @Id = @IlId, @MinQuantity = 20, @MaxQuantity = 200,
    @DefaultQuantity = 75, @IsConsumptionPoint = 0, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #SM);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #SM;

EXEC test.Assert_IsEqual
    @TestName = N'[SetConsumptionMetadata] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @Min INT, @CP BIT;
SELECT @Min = MinQuantity, @CP = IsConsumptionPoint
FROM Parts.ItemLocation WHERE Id = @IlId;

DECLARE @MinStr NVARCHAR(10) = CAST(@Min AS NVARCHAR(10));
DECLARE @CPStr NVARCHAR(1) = CAST(@CP AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SetConsumptionMetadata] MinQuantity changed to 20',
    @Expected = N'20', @Actual = @MinStr;
EXEC test.Assert_IsEqual
    @TestName = N'[SetConsumptionMetadata] IsConsumptionPoint flipped to 0',
    @Expected = N'0', @Actual = @CPStr;
GO

-- =============================================
-- Test 8: SetConsumptionMetadata rejects Min > Max
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PH-E-TEST-001');
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');
DECLARE @IlId BIGINT = (
    SELECT Id FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @LocId AND DeprecatedAt IS NULL);

CREATE TABLE #SM2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #SM2 EXEC Parts.ItemLocation_SetConsumptionMetadata
    @Id = @IlId, @MinQuantity = 500, @MaxQuantity = 50,
    @IsConsumptionPoint = 1, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #SM2);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #SM2;

EXEC test.Assert_IsEqual
    @TestName = N'[SetConsumptionMetadata Min>Max] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 9: Workorder.WorkOrderType_List has 1 seed row (post-OI-07)
-- =============================================
-- OI-07 correction (migration 0013) collapsed the original 3-type seed
-- (Demand / Maintenance / Recipe) to a single Production row.
-- Maintenance + Recipe are FUTURE hooks.
CREATE TABLE #WT (Id BIGINT, Code NVARCHAR(20), Name NVARCHAR(100), Description NVARCHAR(500));
INSERT INTO #WT EXEC Workorder.WorkOrderType_List;
DECLARE @Count INT = (SELECT COUNT(*) FROM #WT);
EXEC test.Assert_RowCount
    @TestName = N'[WorkOrderType_List] 1 seed row',
    @ExpectedCount = 1, @ActualCount = @Count;

DECLARE @HasProduction INT = (SELECT COUNT(*) FROM #WT WHERE Code = N'Production');
DECLARE @HasProductionStr NVARCHAR(5) = CAST(@HasProduction AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[WorkOrderType_List] Contains Production',
    @Expected = N'1', @Actual = @HasProductionStr;
DROP TABLE #WT;
GO

-- =============================================
-- Test 10: Workorder.ScrapSource_List has 2 seed rows
-- =============================================
CREATE TABLE #SS (Id BIGINT, Code NVARCHAR(20), Name NVARCHAR(100), Description NVARCHAR(500));
INSERT INTO #SS EXEC Workorder.ScrapSource_List;
DECLARE @Count INT = (SELECT COUNT(*) FROM #SS);
EXEC test.Assert_RowCount
    @TestName = N'[ScrapSource_List] 2 seed rows',
    @ExpectedCount = 2, @ActualCount = @Count;

DECLARE @HasInv INT = (SELECT COUNT(*) FROM #SS WHERE Code = N'Inventory');
DECLARE @HasLoc INT = (SELECT COUNT(*) FROM #SS WHERE Code = N'Location');
DECLARE @HasInvStr NVARCHAR(5) = CAST(@HasInv AS NVARCHAR(5));
DECLARE @HasLocStr NVARCHAR(5) = CAST(@HasLoc AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[ScrapSource_List] Contains Inventory',
    @Expected = N'1', @Actual = @HasInvStr;
EXEC test.Assert_IsEqual
    @TestName = N'[ScrapSource_List] Contains Location',
    @Expected = N'1', @Actual = @HasLocStr;
DROP TABLE #SS;
GO

EXEC test.PrintSummary;
GO
