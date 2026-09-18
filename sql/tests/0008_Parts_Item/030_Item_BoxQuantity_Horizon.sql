-- =============================================
-- File:         0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Parts.Item.BoxQuantity / LowInventoryHorizon (migration 0091) and
--               their Parts.Item_Update rules (line inventory sidebar spec).
--               Phase 1: columns + positive CHECKs exist.
--               Phase 2+: Item_Update validation / preserve / clear / audit.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql';
GO

-- ---- cleanup ----
DELETE FROM Audit.ConfigLog
    WHERE LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Item')
      AND EntityId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'T030-%');
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T030-%';
GO

-- ---- fixture: one PassThrough, one FinishedGood, one Component ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES
    ((SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough'),  N'T030-PT', N'T030 dowel pin', 1, @Now, 1),
    ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'T030-FG', N'T030 finished',  1, @Now, 1),
    ((SELECT Id FROM Parts.ItemType WHERE Code = N'Component'),    N'T030-CO', N'T030 casting',   1, @Now, 1);
GO

-- =============================================
-- Phase 1: schema
-- =============================================
DECLARE @HasBox NVARCHAR(1) = CASE WHEN COL_LENGTH('Parts.Item', 'BoxQuantity') IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Item.BoxQuantity exists', @Expected = N'1', @Actual = @HasBox;
DECLARE @HasHz NVARCHAR(1) = CASE WHEN COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Item.LowInventoryHorizon exists', @Expected = N'1', @Actual = @HasHz;
GO

DECLARE @Err NVARCHAR(1) = N'0';
BEGIN TRY
    EXEC(N'UPDATE Parts.Item SET BoxQuantity = 0 WHERE PartNumber = N''T030-PT''');
END TRY
BEGIN CATCH
    SET @Err = N'1';
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] CHECK rejects BoxQuantity = 0', @Expected = N'1', @Actual = @Err;
GO

DECLARE @Err NVARCHAR(1) = N'0';
BEGIN TRY
    EXEC(N'UPDATE Parts.Item SET LowInventoryHorizon = -5 WHERE PartNumber = N''T030-FG''');
END TRY
BEGIN CATCH
    SET @Err = N'1';
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] CHECK rejects negative horizon', @Expected = N'1', @Actual = @Err;
GO

-- =============================================
-- Phase 2: set on the right type
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-FG');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin', @UomId = 1, @AppUserId = 1, @BoxQuantity = 5000;
INSERT INTO @R EXEC Parts.Item_Update @Id = @Fg, @Description = N'T030 finished',  @UomId = 1, @AppUserId = 1, @LowInventoryHorizon = 50;
DECLARE @Ok NVARCHAR(10) = (SELECT CAST(SUM(CAST(Status AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Update] both sets succeed', @Expected = N'2', @Actual = @Ok;
DECLARE @Box NVARCHAR(10) = (SELECT CAST(BoxQuantity AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Update] BoxQuantity stored', @Expected = N'5000', @Actual = @Box;
DECLARE @Hz NVARCHAR(10) = (SELECT CAST(LowInventoryHorizon AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Update] horizon stored', @Expected = N'50', @Actual = @Hz;
DECLARE @Log NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog WHERE EntityId = @Pt ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Update] audit prose names BoxQuantity', @HaystackStr = @Log, @NeedleStr = N'BoxQuantity';
GO

-- =============================================
-- Phase 3: omitted preserves (a save that does not know the fields)
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1;
DECLARE @Box NVARCHAR(10) = (SELECT CAST(BoxQuantity AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Preserve] omitted BoxQuantity kept', @Expected = N'5000', @Actual = @Box;
GO

-- =============================================
-- Phase 4: 0 clears
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = 0;
DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Clear] status 1', @Expected = N'1', @Actual = @S;
DECLARE @IsNull NVARCHAR(1) = (SELECT CASE WHEN BoxQuantity IS NULL THEN N'1' ELSE N'0' END FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Clear] BoxQuantity now NULL', @Expected = N'1', @Actual = @IsNull;
GO

-- =============================================
-- Phase 5: rejections (wrong type, negative)
-- =============================================
DECLARE @Co BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-CO');
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Parts.Item_Update @Id = @Co, @Description = N'T030 casting', @UomId = 1, @AppUserId = 1, @BoxQuantity = 100;
DECLARE @S1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[Reject] BoxQuantity on a Component', @Expected = N'0', @Actual = @S1;
DECLARE @M1 NVARCHAR(500) = (SELECT Message FROM @R1);
EXEC test.Assert_Contains @TestName = N'[Reject] message names PassThrough', @HaystackStr = @M1, @NeedleStr = N'PassThrough';

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @LowInventoryHorizon = 50;
DECLARE @S2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[Reject] horizon on a PassThrough', @Expected = N'0', @Actual = @S2;

DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R3 EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = -1;
DECLARE @S3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[Reject] negative BoxQuantity', @Expected = N'0', @Actual = @S3;
GO

-- =============================================
-- Phase 5b: retype away from PassThrough -- stored value survives a same-value
-- save, blocks a changed value, and 0 still clears (review fix, proc v2.6)
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @ComponentTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');

-- Re-establish a known BoxQuantity on the PassThrough fixture (Phase 4 cleared it).
DECLARE @RSeed TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RSeed EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = 3000;
DECLARE @SeedOk NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @RSeed);
EXEC test.Assert_IsEqual @TestName = N'[Retype] seed BoxQuantity succeeds', @Expected = N'1', @Actual = @SeedOk;

-- Fixture-only shortcut: Item_Update deliberately cannot retype (PartNumber +
-- ItemTypeId are immutable per the proc), so retype the fixture row directly.
UPDATE Parts.Item SET ItemTypeId = @ComponentTypeId WHERE Id = @Pt;

-- (a) Same stored value passed back -- must SUCCEED even though the item is now
-- a Component (not PassThrough).
DECLARE @Ra TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Ra EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = 3000;
DECLARE @Sa NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @Ra);
EXEC test.Assert_IsEqual @TestName = N'[Retype] same value on retyped item succeeds', @Expected = N'1', @Actual = @Sa;
DECLARE @BoxA NVARCHAR(10) = (SELECT CAST(BoxQuantity AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Retype] BoxQuantity unchanged at 3000', @Expected = N'3000', @Actual = @BoxA;

-- (b) A DIFFERENT positive value on the retyped item -- must be REJECTED.
DECLARE @Rb TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Rb EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = 4000;
DECLARE @Sb NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @Rb);
EXEC test.Assert_IsEqual @TestName = N'[Retype] different value on retyped item rejected', @Expected = N'0', @Actual = @Sb;
DECLARE @Mb NVARCHAR(500) = (SELECT Message FROM @Rb);
EXEC test.Assert_Contains @TestName = N'[Retype] reject message names PassThrough', @HaystackStr = @Mb, @NeedleStr = N'PassThrough';
DECLARE @BoxB NVARCHAR(10) = (SELECT CAST(BoxQuantity AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Retype] BoxQuantity still 3000 after rejected change', @Expected = N'3000', @Actual = @BoxB;

-- (c) 0 still clears on the retyped item.
DECLARE @Rc TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Rc EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = 0;
DECLARE @Sc NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @Rc);
EXEC test.Assert_IsEqual @TestName = N'[Retype] 0 clears on retyped item succeeds', @Expected = N'1', @Actual = @Sc;
DECLARE @IsNullC NVARCHAR(1) = (SELECT CASE WHEN BoxQuantity IS NULL THEN N'1' ELSE N'0' END FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Retype] BoxQuantity cleared to NULL', @Expected = N'1', @Actual = @IsNullC;

-- Restore the fixture back to PassThrough so it doesn't confuse itself if this
-- file is ever re-run without a full reset, and so its type matches its name.
UPDATE Parts.Item SET ItemTypeId = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough') WHERE Id = @Pt;
GO

-- =============================================
-- Phase 6: Item_Get returns both (last two columns)
-- =============================================
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-FG');
CREATE TABLE #G (
    Id BIGINT, ItemTypeId BIGINT, ItemTypeName NVARCHAR(100), PartNumber NVARCHAR(50), Description NVARCHAR(500),
    MacolaPartNumber NVARCHAR(50), DefaultSubLotQty INT, MaxLotSize INT, UomId BIGINT, UomCode NVARCHAR(20),
    UnitWeight DECIMAL(10,4), WeightUomId BIGINT, WeightUomCode NVARCHAR(20), CountryOfOrigin NVARCHAR(2),
    MaxParts INT, CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), CreatedByUserId BIGINT, UpdatedByUserId BIGINT,
    DeprecatedAt DATETIME2(3), CrtEnabled BIT, BoxQuantity INT, LowInventoryHorizon INT);
INSERT INTO #G EXEC Parts.Item_Get @Id = @Fg;
DECLARE @GHz NVARCHAR(10) = (SELECT CAST(LowInventoryHorizon AS NVARCHAR(10)) FROM #G);
DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName = N'[Get] horizon returned', @Expected = N'50', @Actual = @GHz;
GO

-- ---- cleanup ----
DELETE FROM Audit.ConfigLog
    WHERE LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Item')
      AND EntityId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'T030-%');
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T030-%';
GO

EXEC test.EndTestFile;
GO
