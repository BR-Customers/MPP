-- =============================================
-- File: 0008_Parts_Item/027_ContainerConfig_resolve.sql
-- Desc: GetByItem returns all per-method configs; GetByItemAndMethod resolves
--       a single one; ContainerConfig_Update rejects a ClosureMethod change.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/027_ContainerConfig_resolve.sql';
GO

DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-RES';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-RES';
GO
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-RES', @Description = N'res', @UomId = 1, @AppUserId = 1;
DECLARE @Item BIGINT = (SELECT NewId FROM @R);
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 1, 48, 0, N'ByCount', SYSUTCDATETIME());
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 12, 8, 0, N'ByVision', SYSUTCDATETIME());
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-RES');

-- GetByItem returns both
CREATE TABLE #All (Id BIGINT, ItemId BIGINT, TraysPerContainer INT, PartsPerTray INT, IsSerialized BIT, DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50), ClosureMethod NVARCHAR(20), TargetWeight DECIMAL(10,4), CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #All EXEC Parts.ContainerConfig_GetByItem @ItemId = @Item;
DECLARE @AllCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #All);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] GetByItem returns 2 rows', @Expected = N'2', @Actual = @AllCnt;

-- GetByItemAndMethod resolves the ByVision one (12x8)
CREATE TABLE #One (Id BIGINT, ItemId BIGINT, TraysPerContainer INT, PartsPerTray INT, IsSerialized BIT, DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50), ClosureMethod NVARCHAR(20), TargetWeight DECIMAL(10,4), CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #One EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @Item, @ClosureMethod = N'ByVision';
DECLARE @VisPpt NVARCHAR(10) = (SELECT CAST(PartsPerTray AS NVARCHAR(10)) FROM #One);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] GetByItemAndMethod picks ByVision PartsPerTray', @Expected = N'8', @Actual = @VisPpt;

-- Update immutability: changing the method is rejected.
DECLARE @CcId BIGINT = (SELECT Id FROM #All WHERE ClosureMethod = N'ByCount');
CREATE TABLE #Upd (Status BIT, Message NVARCHAR(500));
INSERT INTO #Upd EXEC Parts.ContainerConfig_Update
    @Id = @CcId, @TraysPerContainer = 1, @PartsPerTray = 48, @IsSerialized = 0,
    @ClosureMethod = N'ByVision', @AppUserId = 1;
DECLARE @UpdStat NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Upd);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] Update rejects ClosureMethod change (Status 0)', @Expected = N'0', @Actual = @UpdStat;

DROP TABLE #All; DROP TABLE #One; DROP TABLE #Upd;
GO

DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-RES';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-RES';
GO
EXEC test.EndTestFile;
GO
