-- =============================================
-- File: 0008_Parts_Item/026_ContainerConfig_multi_method.sql
-- Desc: Two active configs per item allowed when ClosureMethod differs;
--       a second config with the SAME method is rejected by the index.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/026_ContainerConfig_multi_method.sql';
GO

-- cleanup + host item
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-MULTI';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-MULTI';
GO
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-MULTI', @Description = N'multi', @UomId = 1, @AppUserId = 1;
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-MULTI');

-- ByCount config
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 1, 48, 0, N'ByCount', SYSUTCDATETIME());
-- ByVision config for the SAME item (must be allowed)
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 12, 8, 0, N'ByVision', SYSUTCDATETIME());

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[CCMulti] two active configs, different methods, allowed', @Expected = N'2', @Actual = @N;

-- second ByCount must violate the (ItemId, ClosureMethod) unique index
DECLARE @Err NVARCHAR(10) = N'0';
BEGIN TRY
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 1, 48, 0, N'ByCount', SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SET @Err = N'1';
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[CCMulti] duplicate (item, method) rejected by index', @Expected = N'1', @Actual = @Err;
GO

DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-MULTI';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-MULTI';
GO
EXEC test.EndTestFile;
GO
