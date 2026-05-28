-- =============================================
-- File:         0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-27
-- Description:  Test fixtures for Parts.ItemLocation_SaveAllForItem.
--               Covers add/update/deprecate/reactivate paths and
--               validation rejections.
--
--               Pre-conditions:
--                 - Migration 0001-0010 applied
--                 - AppUser Id=1 exists
--                 - Seed Locations present across all tiers
--                 - Parts.ItemLocation_SaveAllForItem deployed
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql';
GO

-- Test setup: create test Item if it doesn't already exist
DECLARE @TestItemPart NVARCHAR(50) = N'TEST-ELIG-ITEM-001';
DECLARE @TestItemId   BIGINT       = (SELECT Id FROM Parts.Item WHERE PartNumber = @TestItemPart AND DeprecatedAt IS NULL);

IF @TestItemId IS NULL
BEGIN
    DECLARE @ItId BIGINT = (SELECT TOP 1 Id FROM Parts.ItemType);
    DECLARE @UmId BIGINT = (SELECT TOP 1 Id FROM Parts.Uom);
    INSERT INTO Parts.Item (PartNumber, Description, ItemTypeId, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TestItemPart, N'Eligibility SaveAll test item', @ItId, @UmId, SYSUTCDATETIME(), 1);
    SET @TestItemId = SCOPE_IDENTITY();
END
GO

-- =============================================
-- Test 1: SaveAll empty payload on Item with no existing rows -> Status=1, 0 rows
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');

-- Ensure baseline: deprecate any leftover rows from prior runs
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = N'[]',
    @AppUserId = 1;

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = N'[]',
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligSaveEmpty] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 2: Add a new row (Id=NULL) at an Area-tier Location
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}]';

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligAddRow] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.ItemLocation
                    WHERE ItemId = @TestItemId AND LocationId = @LocId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[EligAddRow] Exactly one active row exists',
    @Expected = N'1',
    @Actual   = @CntStr;
GO

-- =============================================
-- Test 3: Empty SaveAll deprecates the row added in Test 2
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = N'[]',
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligDeprecateAll] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @ActiveCnt INT = (SELECT COUNT(*) FROM Parts.ItemLocation
                          WHERE ItemId = @TestItemId AND DeprecatedAt IS NULL);
DECLARE @ActiveStr NVARCHAR(10) = CAST(@ActiveCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[EligDeprecateAll] Zero active rows after empty save',
    @Expected = N'0',
    @Actual   = @ActiveStr;
GO

-- =============================================
-- Test 4: Reactivate the previously-deprecated pairing via Id=NULL + matching LocationId
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @PriorDeprecatedId BIGINT = (SELECT TOP 1 Id FROM Parts.ItemLocation
                                     WHERE ItemId = @TestItemId AND LocationId = @LocId
                                       AND DeprecatedAt IS NOT NULL
                                     ORDER BY Id);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}]';

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligReactivate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- The previously-deprecated Id should now be active again (no new row created)
DECLARE @ReactivatedDepAt DATETIME2(3);
SELECT @ReactivatedDepAt = DeprecatedAt FROM Parts.ItemLocation WHERE Id = @PriorDeprecatedId;
DECLARE @ReactivatedStr NVARCHAR(1) = CASE WHEN @ReactivatedDepAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[EligReactivate] Original Id has DeprecatedAt cleared',
    @Expected = N'1',
    @Actual   = @ReactivatedStr;
GO

-- =============================================
-- Test 5: Consumption-point row missing qty -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Cell' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":true,"MinQuantity":null,"MaxQuantity":200,"DefaultQuantity":100}]';

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligCspMissingQty] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 6: Min > Max -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Cell' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":true,"MinQuantity":200,"MaxQuantity":50,"DefaultQuantity":100}]';

CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligMinGtMax] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 7: Duplicate LocationId in payload -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Cell' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[' +
    N'{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) + N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null},' +
    N'{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) + N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}' +
    N']';

CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R7;
DROP TABLE #R7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligDuplicate] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 8: ItemId not found -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);

CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R8
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = 9999999999,
    @RowsJson  = N'[]',
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R8;
DROP TABLE #R8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligBadItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

EXEC test.EndTestFile;
GO
