-- =============================================
-- File: 0028_PlantFloor_Assembly/093_Assembly_CompleteTray_by_method.sql
-- Desc: Assembly_CompleteTray resolves the ContainerConfig by (Item, closure
--       method). A method with no configured pack-out is blocked (Status 0)
--       before any BOM/stock work; an invalid method code is rejected.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/093_Assembly_CompleteTray_by_method.sql';
GO

-- cleanup + fixture: FG item eligible at an assembly-out cell, with a ByCount
-- config ONLY (no ByWeight config).
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CT-METHOD';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'TEST-CT-METHOD';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CT-METHOD';
GO
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @RI TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @RI EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CT-METHOD', @Description = N'method test FG', @UomId = 1, @AppUserId = 1;
DECLARE @Fg BIGINT = (SELECT NewId FROM @RI);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Cell, 0, @Now);
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 2, 24, 0, N'ByCount', @Now);
GO

DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CT-METHOD');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- ByWeight requested, but only a ByCount config exists -> blocked, message names the method.
CREATE TABLE #RW (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO #RW EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByWeight', @AppUserId = 1;
DECLARE @WStat NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #RW);
EXEC test.Assert_IsEqual @TestName = N'[ByMethod] ByWeight with no pack-out -> Status 0', @Expected = N'0', @Actual = @WStat;
DECLARE @WMsg NVARCHAR(1) = (SELECT CASE WHEN Message LIKE N'%ByWeight%pack-out%' THEN N'1' ELSE N'0' END FROM #RW);
EXEC test.Assert_IsEqual @TestName = N'[ByMethod] message names the missing method', @Expected = N'1', @Actual = @WMsg;
DROP TABLE #RW;

-- invalid method code -> rejected by the validity guard.
CREATE TABLE #RN (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO #RN EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'Nope', @AppUserId = 1;
DECLARE @NStat NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #RN);
EXEC test.Assert_IsEqual @TestName = N'[ByMethod] invalid method code -> Status 0', @Expected = N'0', @Actual = @NStat;
DROP TABLE #RN;
GO

DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CT-METHOD';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber = N'TEST-CT-METHOD';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CT-METHOD';
GO
EXEC test.EndTestFile;
GO
