-- =============================================
-- File:         0028_PlantFloor_Assembly/070_ContainerTray_Close_insufficient_material.sql
-- Description:  Lots.ContainerTray_Close per-component material gate (Arc 2 Phase 6 /
--               FDS-06-013). A tray can only close when every BOM component has enough
--               open pieces at the cell (need = PartsPerTray x QtyPer). The check is
--               pre-transaction, so a short component rejects cleanly with no partial
--               consumption. Staging more of the short component then lets the tray close.
--               Uses MA1-5GOR-ASER (isolated; no other test stages material there).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/070_ContainerTray_Close_insufficient_material.sql';
GO

DELETE FROM Workorder.ConsumptionEvent WHERE ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-CHILD')
    OR ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-INSUF-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'STG-070A', N'STG-070B'));
DELETE FROM Lots.Lot WHERE LotName IN (N'STG-070A', N'STG-070B');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-INSUF-TEST', N'Phase6 insufficient-material test assembly', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-INSUF-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-INSUF-CHILD', N'Phase6 insufficient-material test component', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 2, 25, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
-- published BOM: P6-INSUF-TEST <- P6-INSUF-CHILD x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Item, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @Child, 1, 1, 1);
END
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-ASER');

-- stage only 30 of the component: enough for one 25-part tray, not two
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-070A', @Child, 1, 1, 30, @Cell, 1);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- tray 1: need 25, have 30 -> closes; component -> 5
DECLARE @T1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @T1 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 25, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T1);
EXEC test.Assert_IsEqual @TestName = N'[Material] tray 1 closes (component 30 >= 25)', @Expected = N'1', @Actual = @S1;
DECLARE @Rem1 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-070A');
EXEC test.Assert_IsEqual @TestName = N'[Material] component decremented 30 -> 5', @Expected = N'5', @Actual = @Rem1;

-- tray 2: need 25, only 5 left -> rejects (pre-txn, no partial consumption)
DECLARE @T2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @T2 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 2, @PartsCount = 25, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T2);
DECLARE @M2 NVARCHAR(500) = (SELECT Message FROM @T2);
DECLARE @MsgOk NVARCHAR(10) = CASE WHEN @M2 LIKE N'%Insufficient P6-INSUF-CHILD%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Material] tray 2 rejects (component 5 < 25)', @Expected = N'0', @Actual = @S2;
EXEC test.Assert_IsEqual @TestName = N'[Material] rejection names the short component', @Expected = N'1', @Actual = @MsgOk;
DECLARE @Rem2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-070A');
EXEC test.Assert_IsEqual @TestName = N'[Material] no partial consumption on reject (still 5)', @Expected = N'5', @Actual = @Rem2;
DECLARE @CeCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Material] only tray 1 consumption recorded', @Expected = N'1', @Actual = @CeCount;

-- stage 50 more (component now 55) -> tray 2 closes
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-070B', @Child, 1, 1, 50, @Cell, 1);
DECLARE @T3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @T3 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 2, @PartsCount = 25, @AppUserId = 1;
DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T3);
EXEC test.Assert_IsEqual @TestName = N'[Material] tray 2 closes after staging more (55 >= 25)', @Expected = N'1', @Actual = @S3;
GO

DELETE FROM Workorder.ConsumptionEvent WHERE ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-CHILD')
    OR ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-INSUF-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'STG-070A', N'STG-070B'));
DELETE FROM Lots.Lot WHERE LotName IN (N'STG-070A', N'STG-070B');
GO

EXEC test.EndTestFile;
GO
