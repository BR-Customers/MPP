-- =============================================
-- File:         0009_Parts_Process/070_ItemLocation_SetMaxQuantity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:
--   Tests for Parts.ItemLocation_SetMaxQuantity, the proc behind the shop-floor
--   Line Inventory "Tolerances" popup (Task R3). Touches ONLY MaxQuantity;
--   Min/Default are set once in the fixture and must never move.
--
--   Placed in this suite (not 0008_Parts_Item) because the existing
--   ItemLocation tests (Add/Remove/List, SaveAllForItem) live here in
--   030_ItemLocation_crud.sql / 040_ItemLocation_SaveAllForItem.sql.
--
--   Covers: raise Max (audits once, Min/Default untouched), idempotent
--   re-set (no-op, no audit row), clear to NULL, reject <= 0, reject below
--   Min (message mentions Min), reject a non-consumption row, reject a
--   deprecated row, reject a NULL Id.
--
--   Pre-conditions:
--     - Migrations through 0010 (ItemLocation consumption metadata columns)
--     - AppUser Id=1 exists
--     - MPP plant seed (011): Location MA1-COMPBR exists
--     - Parts.ItemLocation_SetMaxQuantity deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/070_ItemLocation_SetMaxQuantity.sql';
GO

-- =============================================
-- Cleanup (leading): ConfigLog -> ItemLocation -> Item
-- =============================================
DELETE cl FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId AND let.Code = N'ItemLocation'
    INNER JOIN Parts.ItemLocation il ON il.Id = cl.EntityId
    INNER JOIN Parts.Item i ON i.Id = il.ItemId
    WHERE i.PartNumber LIKE N'T070-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T070-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T070-%';
GO

-- =============================================
-- Fixture
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @App BIGINT = 1;
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @UomId BIGINT = (SELECT TOP 1 Id FROM Parts.Uom WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES
    (@TPt, N'T070-PIN', N'T070 dowel pin',     @UomId, @Now, @App),
    (@TPt, N'T070-NC',  N'T070 non-consump',   @UomId, @Now, @App),
    (@TPt, N'T070-DEP', N'T070 deprecated row',@UomId, @Now, @App);

DECLARE @PinItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T070-PIN');
DECLARE @NcItemId  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T070-NC');
DECLARE @DepItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T070-DEP');

-- Consumption row: Min 20, Max 500, Default 40
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MinQuantity, MaxQuantity, DefaultQuantity, IsConsumptionPoint, CreatedAt)
VALUES (@PinItemId, @Line, 20, 500, 40, 1, @Now);

-- Non-consumption row (eligible, not a consumption point)
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
VALUES (@NcItemId, @Line, 0, @Now);

-- Row to be deprecated
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MinQuantity, MaxQuantity, DefaultQuantity, IsConsumptionPoint, CreatedAt)
VALUES (@DepItemId, @Line, 5, 100, 10, 1, @Now);
UPDATE Parts.ItemLocation SET DeprecatedAt = @Now WHERE ItemId = @DepItemId;
GO

-- =============================================
-- Phase (a): raise to 600
-- =============================================
DECLARE @PinIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-PIN');
DECLARE @LogTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ItemLocation');
DECLARE @BeforeCount INT = (SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId = @LogTypeId AND EntityId = @PinIl);

CREATE TABLE #a (Status BIT, Message NVARCHAR(500));
INSERT INTO #a EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @PinIl, @MaxQuantity = 600, @AppUserId = 1;
DECLARE @aStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #a);
EXEC test.Assert_IsEqual @TestName = N'[a] Set 600 -> Status 1', @Expected = N'1', @Actual = @aStatus;

DECLARE @Max600 NVARCHAR(10) = (SELECT CAST(MaxQuantity AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE Id = @PinIl);
EXEC test.Assert_IsEqual @TestName = N'[a] Max is 600', @Expected = N'600', @Actual = @Max600;
DECLARE @Min20 NVARCHAR(10) = (SELECT CAST(MinQuantity AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE Id = @PinIl);
EXEC test.Assert_IsEqual @TestName = N'[a] Min still 20', @Expected = N'20', @Actual = @Min20;
DECLARE @Def40 NVARCHAR(10) = (SELECT CAST(DefaultQuantity AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE Id = @PinIl);
EXEC test.Assert_IsEqual @TestName = N'[a] Default still 40', @Expected = N'40', @Actual = @Def40;

DECLARE @AfterCount INT = (SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId = @LogTypeId AND EntityId = @PinIl);
DECLARE @DeltaA NVARCHAR(10) = CAST(@AfterCount - @BeforeCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[a] exactly one new ConfigLog row', @Expected = N'1', @Actual = @DeltaA;
DECLARE @Desc NVARCHAR(1000) = (SELECT TOP 1 Description FROM Audit.ConfigLog WHERE LogEntityTypeId = @LogTypeId AND EntityId = @PinIl ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[a] ConfigLog Description mentions MaxQuantity', @HaystackStr = @Desc, @NeedleStr = N'MaxQuantity';
DROP TABLE #a;
GO

-- =============================================
-- Phase (b): re-set 600 -> no-op, no new audit row
-- =============================================
DECLARE @PinIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-PIN');
DECLARE @LogTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ItemLocation');
DECLARE @BeforeCount INT = (SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId = @LogTypeId AND EntityId = @PinIl);

CREATE TABLE #b (Status BIT, Message NVARCHAR(500));
INSERT INTO #b EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @PinIl, @MaxQuantity = 600, @AppUserId = 1;
DECLARE @bStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #b);
DECLARE @bMessage NVARCHAR(500) = (SELECT Message FROM #b);
EXEC test.Assert_IsEqual @TestName = N'[b] Re-set 600 -> Status 1', @Expected = N'1', @Actual = @bStatus;
EXEC test.Assert_IsEqual @TestName = N'[b] Message No change.', @Expected = N'No change.', @Actual = @bMessage;

DECLARE @AfterCount INT = (SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId = @LogTypeId AND EntityId = @PinIl);
DECLARE @DeltaB NVARCHAR(10) = CAST(@AfterCount - @BeforeCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[b] no new ConfigLog row', @Expected = N'0', @Actual = @DeltaB;
DROP TABLE #b;
GO

-- =============================================
-- Phase (c): NULL clears Max, Min/Default untouched
-- =============================================
DECLARE @PinIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-PIN');
CREATE TABLE #c (Status BIT, Message NVARCHAR(500));
INSERT INTO #c EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @PinIl, @MaxQuantity = NULL, @AppUserId = 1;
DECLARE @cStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #c);
EXEC test.Assert_IsEqual @TestName = N'[c] Set NULL -> Status 1', @Expected = N'1', @Actual = @cStatus;
DECLARE @cMax NVARCHAR(10) = (SELECT CAST(MaxQuantity AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE Id = @PinIl);
EXEC test.Assert_IsNull @TestName = N'[c] Max is NULL', @Value = @cMax;
DECLARE @Min20c NVARCHAR(10) = (SELECT CAST(MinQuantity AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE Id = @PinIl);
EXEC test.Assert_IsEqual @TestName = N'[c] Min still 20', @Expected = N'20', @Actual = @Min20c;
DECLARE @Def40c NVARCHAR(10) = (SELECT CAST(DefaultQuantity AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE Id = @PinIl);
EXEC test.Assert_IsEqual @TestName = N'[c] Default still 40', @Expected = N'40', @Actual = @Def40c;
DROP TABLE #c;
GO

-- =============================================
-- Phase (d): 0 is rejected
-- =============================================
DECLARE @PinIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-PIN');
CREATE TABLE #d (Status BIT, Message NVARCHAR(500));
INSERT INTO #d EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @PinIl, @MaxQuantity = 0, @AppUserId = 1;
DECLARE @dStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #d);
EXEC test.Assert_IsEqual @TestName = N'[d] 0 rejected', @Expected = N'0', @Actual = @dStatus;
DROP TABLE #d;
GO

-- =============================================
-- Phase (e): -5 is rejected
-- =============================================
DECLARE @PinIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-PIN');
CREATE TABLE #e (Status BIT, Message NVARCHAR(500));
INSERT INTO #e EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @PinIl, @MaxQuantity = -5, @AppUserId = 1;
DECLARE @eStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #e);
EXEC test.Assert_IsEqual @TestName = N'[e] -5 rejected', @Expected = N'0', @Actual = @eStatus;
DROP TABLE #e;
GO

-- =============================================
-- Phase (f): 10 rejected (below Min 20), message mentions Min
-- =============================================
DECLARE @PinIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-PIN');
CREATE TABLE #f (Status BIT, Message NVARCHAR(500));
INSERT INTO #f EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @PinIl, @MaxQuantity = 10, @AppUserId = 1;
DECLARE @fStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #f);
DECLARE @fMessage NVARCHAR(500) = (SELECT Message FROM #f);
EXEC test.Assert_IsEqual @TestName = N'[f] 10 rejected (below Min 20)', @Expected = N'0', @Actual = @fStatus;
EXEC test.Assert_Contains @TestName = N'[f] message mentions Min', @HaystackStr = @fMessage, @NeedleStr = N'Min';
DROP TABLE #f;
GO

-- =============================================
-- Phase (g): non-consumption row is rejected
-- =============================================
DECLARE @NcIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-NC');
CREATE TABLE #g (Status BIT, Message NVARCHAR(500));
INSERT INTO #g EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @NcIl, @MaxQuantity = 100, @AppUserId = 1;
DECLARE @gStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[g] non-consumption row rejected', @Expected = N'0', @Actual = @gStatus;
DROP TABLE #g;
GO

-- =============================================
-- Phase (h): deprecated row is rejected
-- =============================================
DECLARE @DepIl BIGINT = (SELECT il.Id FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'T070-DEP');
CREATE TABLE #h (Status BIT, Message NVARCHAR(500));
INSERT INTO #h EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = @DepIl, @MaxQuantity = 200, @AppUserId = 1;
DECLARE @hStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #h);
EXEC test.Assert_IsEqual @TestName = N'[h] deprecated row rejected', @Expected = N'0', @Actual = @hStatus;
DROP TABLE #h;
GO

-- =============================================
-- Phase (i): NULL @ItemLocationId is rejected
-- =============================================
CREATE TABLE #i (Status BIT, Message NVARCHAR(500));
INSERT INTO #i EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = NULL, @MaxQuantity = 100, @AppUserId = 1;
DECLARE @iStatus NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #i);
EXEC test.Assert_IsEqual @TestName = N'[i] NULL Id rejected', @Expected = N'0', @Actual = @iStatus;
DROP TABLE #i;
GO

-- =============================================
-- Cleanup (trailing): ConfigLog -> ItemLocation -> Item
-- =============================================
DELETE cl FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId AND let.Code = N'ItemLocation'
    INNER JOIN Parts.ItemLocation il ON il.Id = cl.EntityId
    INNER JOIN Parts.Item i ON i.Id = il.ItemId
    WHERE i.PartNumber LIKE N'T070-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T070-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T070-%';
GO

EXEC test.EndTestFile;
GO
