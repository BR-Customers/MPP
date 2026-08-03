-- =============================================
-- File: 0049_AimIntegration/050_Item_accessors.sql
-- Desc: Item AIM customer-part accessors round-trip, allow clearing, and audit.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/050_Item_accessors.sql';
GO

-- Cleanup (idempotent, run before AND after). AIM-P1-T6 is a bare Parts.Item row
-- with no ContainerConfig/Lot/ItemLocation fixture built against it in this file,
-- so it is referenced by nothing and a direct delete is safe.
DELETE FROM Audit.ConfigLog WHERE Description LIKE N'%AIM-P1-T6%';
DELETE FROM Parts.Item WHERE PartNumber = N'AIM-P1-T6';
GO

-- -SkipDemoSeed leaves Parts.Item without demo rows; create our own.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-T6')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-T6', N'AIM plan-1 accessor test part', 1, @Now, 1);
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T6');

DECLARE @S TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @S EXEC Parts.Item_SetAimCustomerPartNumber
    @ItemId = @ItemId, @Value = N'112006FB A000', @AppUserId = @UserId;
DECLARE @SetOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @S);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Item_SetAimCustomerPartNumber succeeds',
    @Expected = N'1', @Actual = @SetOk;

DECLARE @G TABLE (ItemId BIGINT, AimCustomerPartNumber NVARCHAR(50));
INSERT INTO @G EXEC Parts.Item_GetAimCustomerPartNumber @ItemId = @ItemId;
DECLARE @Got NVARCHAR(50) = (SELECT AimCustomerPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Item_GetAimCustomerPartNumber round-trips the value',
    @Expected = N'112006FB A000', @Actual = @Got;

-- The embedded space is significant to AIM's lookup and must survive.
DECLARE @Len NVARCHAR(10) = (SELECT CAST(LEN(AimCustomerPartNumber + N'.') - 1 AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] embedded space preserved (13 characters)',
    @Expected = N'13', @Actual = @Len;

-- Clearing is legal - an item may stop shipping to Honda.
DELETE FROM @S;
INSERT INTO @S EXEC Parts.Item_SetAimCustomerPartNumber
    @ItemId = @ItemId, @Value = NULL, @AppUserId = @UserId;
DECLARE @Cleared NVARCHAR(10) = (SELECT CASE WHEN AimCustomerPartNumber IS NULL THEN N'1' ELSE N'0' END
    FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] setting NULL clears the value',
    @Expected = N'1', @Actual = @Cleared;

-- Unknown item is rejected, not silently ignored.
DELETE FROM @S;
INSERT INTO @S EXEC Parts.Item_SetAimCustomerPartNumber
    @ItemId = 99999999, @Value = N'X', @AppUserId = @UserId;
DECLARE @Bad NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @S);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] unknown item rejected',
    @Expected = N'0', @Actual = @Bad;

DELETE FROM @G;
INSERT INTO @G EXEC Parts.Item_GetAimCustomerPartNumber @ItemId = 99999999;
DECLARE @NoRow NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] get on unknown item returns empty rowset',
    @Expected = N'0', @Actual = @NoRow;
GO

EXEC test.EndTestFile;
GO

-- Cleanup (idempotent; mirrors the top block).
DELETE FROM Audit.ConfigLog WHERE Description LIKE N'%AIM-P1-T6%';
DELETE FROM Parts.Item WHERE PartNumber = N'AIM-P1-T6';
GO
