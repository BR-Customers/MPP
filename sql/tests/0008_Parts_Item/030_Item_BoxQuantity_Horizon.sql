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

-- (Task 2 appends the Item_Update phases above this line.)

-- ---- cleanup ----
DELETE FROM Audit.ConfigLog
    WHERE LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Item')
      AND EntityId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'T030-%');
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T030-%';
GO

EXEC test.EndTestFile;
GO
