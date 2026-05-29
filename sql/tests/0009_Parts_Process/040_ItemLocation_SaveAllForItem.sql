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
    VALUES (@TestItemPart, N'Eligibility map test item', @ItId, @UmId, SYSUTCDATETIME(), 1);
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

-- =============================================
-- Test 9: Activity Description has SUBJECT · Eligibility · prefix
--   Reset to empty, then add an Area-tier row; the freshest ConfigLog
--   row for this Item should carry the convention narrative.
-- =============================================
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @ItemLocTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ItemLocation');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

-- Reset to empty baseline
EXEC Parts.ItemLocation_SaveAllForItem @ItemId = @TestItemId, @RowsJson = N'[]', @AppUserId = 1;

-- Add the Area-tier row
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}]';
CREATE TABLE #R9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R9
EXEC Parts.ItemLocation_SaveAllForItem @ItemId = @TestItemId, @RowsJson = @Json, @AppUserId = 1;
DROP TABLE #R9;

DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @TestItemId AND LogEntityTypeId = @ItemLocTypeId
                               ORDER BY Id DESC);
DECLARE @Pattern NVARCHAR(200) = N'TEST-ELIG-ITEM-001%' + Audit.ufn_MidDot() + N' Eligibility ' + Audit.ufn_MidDot() + N'%';
DECLARE @Match NVARCHAR(1) = CASE WHEN @Desc LIKE @Pattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[EligActivityPrefix] Description has SUBJECT mid-dot Eligibility mid-dot prefix',
    @Expected = N'1',
    @Actual   = @Match;
GO

-- =============================================
-- Test 10: Activity Description includes the added Location Code with + prefix
-- =============================================
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @ItemLocTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ItemLocation');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
                          WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);
DECLARE @Code NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @LocId);

DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @TestItemId AND LogEntityTypeId = @ItemLocTypeId
                               ORDER BY Id DESC);
DECLARE @Match NVARCHAR(1) = CASE WHEN @Desc LIKE N'%+' + @Code + N'%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[EligActivityCode] Description includes +<LocationCode>',
    @Expected = N'1',
    @Actual   = @Match;
GO

-- =============================================
-- Test 11: NewValue JSON contains resolved Location {Id, Code, Name}
-- =============================================
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @ItemLocTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ItemLocation');

DECLARE @NewVal NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Audit.ConfigLog
                                 WHERE EntityId = @TestItemId AND LogEntityTypeId = @ItemLocTypeId
                                 ORDER BY Id DESC);
DECLARE @Resolved NVARCHAR(1) =
    CASE WHEN @NewVal LIKE N'%"Location":%' AND @NewVal LIKE N'%"Code":%' AND @NewVal LIKE N'%"Name":%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[EligResolvedJson] NewValue has resolved Location Id/Code/Name',
    @Expected = N'1',
    @Actual   = @Resolved;
GO

-- =============================================
-- Test 12: Activity prose stays within the 500-char cap
-- =============================================
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @ItemLocTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ItemLocation');

DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @TestItemId AND LogEntityTypeId = @ItemLocTypeId
                               ORDER BY Id DESC);
DECLARE @WithinCap NVARCHAR(1) = CASE WHEN LEN(@Desc) <= 500 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[EligActivityCap] Description length <= 500',
    @Expected = N'1',
    @Actual   = @WithinCap;
GO

EXEC test.EndTestFile;
GO
