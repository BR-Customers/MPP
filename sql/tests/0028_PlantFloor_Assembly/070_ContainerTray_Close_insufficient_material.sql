-- =============================================
-- File:         0028_PlantFloor_Assembly/070_ContainerTray_Close_insufficient_material.sql
-- Description:  Lots.ContainerTray_Close cell-material gate (Arc 2 Phase 6). A tray can only
--               be closed when the cell has enough OPEN input parts (the routed machined
--               material) to cover the trays closed so far + this one. Cumulative: enough
--               for tray 1 but not tray 2 rejects; staging more then lets tray 2 close.
--               Uses MA1-5GOR-ASER (isolated; no other test stages material there).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/070_ContainerTray_Close_insufficient_material.sql';
GO

DELETE FROM Lots.Lot WHERE LotName IN (N'STG-070A', N'STG-070B');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-INSUF-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-INSUF-TEST', N'Phase6 insufficient-material test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 2, 25, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-ASER');

-- stage only 30 parts at the cell: enough for one 25-part tray, NOT for two (50)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-070A', @Item, 1, 1, 30, @Cell, 1);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- tray 1: 30 available >= 25 -> closes
DECLARE @T1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @T1 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 25, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T1);
EXEC test.Assert_IsEqual @TestName = N'[Material] tray 1 closes (30 staged >= 25)', @Expected = N'1', @Actual = @S1;

-- tray 2: cumulative 50 > 30 available -> rejects
DECLARE @T2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @T2 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 2, @PartsCount = 25, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T2);
DECLARE @M2 NVARCHAR(500) = (SELECT Message FROM @T2);
DECLARE @MsgOk NVARCHAR(10) = CASE WHEN @M2 LIKE N'%Not enough parts at this cell%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Material] tray 2 rejects (cumulative 50 > 30 staged)', @Expected = N'0', @Actual = @S2;
EXEC test.Assert_IsEqual @TestName = N'[Material] rejection message mentions not enough', @Expected = N'1', @Actual = @MsgOk;
DECLARE @Acc NVARCHAR(10) = (SELECT CAST(ISNULL(SUM(PartsClosedCount),0) AS NVARCHAR(10)) FROM Lots.ContainerTray WHERE ContainerId = @Cid AND ClosedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[Material] accumulated stays 25 after rejected tray', @Expected = N'25', @Actual = @Acc;

-- stage 50 more (total 80) -> tray 2 now closes
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-070B', @Item, 1, 1, 50, @Cell, 1);
DECLARE @T3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @T3 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 2, @PartsCount = 25, @AppUserId = 1;
DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T3);
EXEC test.Assert_IsEqual @TestName = N'[Material] tray 2 closes after staging more (80 >= 50)', @Expected = N'1', @Actual = @S3;
GO

DELETE FROM Lots.Lot WHERE LotName IN (N'STG-070A', N'STG-070B');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-INSUF-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-INSUF-TEST');
GO

EXEC test.EndTestFile;
GO
