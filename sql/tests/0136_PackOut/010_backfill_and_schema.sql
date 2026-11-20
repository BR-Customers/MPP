-- =============================================
-- File: 0136_PackOut/010_backfill_and_schema.sql
-- Desc: Migration 0136 -- every ContainerConfig row is a version of a PackOut
--       header; one active default per (item, method); the uniqueness rules
--       (one default, one active name, one active version) hold.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0136_PackOut/010_backfill_and_schema.sql';
GO

-- ---- Backfill shape over the seeded data ----
DECLARE @NullHdr NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ContainerConfig WHERE PackOutId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Backfill] every ContainerConfig has a PackOutId', @Expected = N'0', @Actual = @NullHdr;

DECLARE @NoDefault NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM (
        SELECT DISTINCT cc.ItemId, cc.ClosureMethod FROM Parts.ContainerConfig cc WHERE cc.DeprecatedAt IS NULL) g
    WHERE NOT EXISTS (SELECT 1 FROM Parts.PackOut p WHERE p.ItemId = g.ItemId AND p.ClosureMethod = g.ClosureMethod
                      AND p.IsDefault = 1 AND p.DeprecatedAt IS NULL));
EXEC test.Assert_IsEqual @TestName = N'[Backfill] every (item, method) with an active config has an active default', @Expected = N'0', @Actual = @NoDefault;

DECLARE @Mismatch NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ContainerConfig cc
    JOIN Parts.PackOut p ON p.Id = cc.PackOutId
    WHERE p.ItemId <> cc.ItemId OR p.ClosureMethod <> cc.ClosureMethod);
EXEC test.Assert_IsEqual @TestName = N'[Backfill] version item/method equal the header''s', @Expected = N'0', @Actual = @Mismatch;

DECLARE @SeedName NVARCHAR(50) = (
    SELECT TOP 1 p.Name FROM Parts.PackOut p JOIN Parts.Item i ON i.Id = p.ItemId
    WHERE i.PartNumber = N'5G0-FG' AND p.DeprecatedAt IS NULL ORDER BY p.Id);
DECLARE @SeedMethodName NVARCHAR(50) = (
    SELECT TOP 1 m.Name FROM Parts.PackOut p JOIN Parts.Item i ON i.Id = p.ItemId
    JOIN Parts.ClosureMethodCode m ON m.Code = p.ClosureMethod
    WHERE i.PartNumber = N'5G0-FG' AND p.DeprecatedAt IS NULL ORDER BY p.Id);
EXEC test.Assert_IsEqual @TestName = N'[Backfill] seeded header is named after its method', @Expected = @SeedMethodName, @Actual = @SeedName;
GO

-- ---- Constraint behaviour on a scratch part ----
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-PO-SCHEMA';
GO
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-PO-SCHEMA', @Description = N'po schema', @UomId = 1, @AppUserId = 1;
DECLARE @Item BIGINT = (SELECT NewId FROM @R);

INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByWeight', N'Tote', 1, 1);
DECLARE @Po BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray, IsSerialized, TargetWeight, ToleranceWeight)
VALUES (@Item, N'ByWeight', @Po, 1, 4, 8, 0, 62.0, 1.5);

DECLARE @Err INT;

SET @Err = 0;
BEGIN TRY
    INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByWeight', N'Cardboard', 1, 1);
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); END CATCH
DECLARE @E1 NVARCHAR(10) = CAST(@Err AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Schema] second active default refused', @Expected = N'2601', @Actual = @E1;

SET @Err = 0;
BEGIN TRY
    INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByWeight', N'tote', 0, 1);
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); END CATCH
DECLARE @E2 NVARCHAR(10) = CAST(@Err AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Schema] duplicate active name refused (case-insensitive)', @Expected = N'2601', @Actual = @E2;

SET @Err = 0;
BEGIN TRY
    INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray, IsSerialized)
    VALUES (@Item, N'ByWeight', @Po, 2, 4, 6, 0);
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); END CATCH
DECLARE @E3 NVARCHAR(10) = CAST(@Err AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Schema] second active version per pack-out refused', @Expected = N'2601', @Actual = @E3;

-- A different method for the same part is its own default.
SET @Err = 0;
BEGIN TRY
    INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByCount', N'Tote', 1, 1);
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); END CATCH
DECLARE @E4 NVARCHAR(10) = CAST(@Err AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Schema] same name + default allowed under another method', @Expected = N'0', @Actual = @E4;
GO

DELETE cc FROM Parts.ContainerConfig cc JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-PO-SCHEMA';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-PO-SCHEMA';
DECLARE @Left NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.PackOut p
                              WHERE NOT EXISTS (SELECT 1 FROM Parts.Item i WHERE i.Id = p.ItemId));
EXEC test.Assert_IsEqual @TestName = N'[Schema] deleting a part removes its pack-out headers', @Expected = N'0', @Actual = @Left;
GO
EXEC test.EndTestFile;
GO
