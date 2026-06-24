-- =============================================
-- File:         0028_PlantFloor_Assembly/020_ContainerTray_Close_methods.sql
-- Description:  Lots.ContainerTray_Close (Arc 2 Phase 6 / FDS-06-014). ByCount /
--               ClosureMethod derived from the ContainerConfig (ByVision here), ignoring any
--               passed value; running accumulated parts; mismatched count rejects; re-close
--               of a position rejects; cell must have enough staged input parts.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/020_ContainerTray_Close_methods.sql';
GO

-- ---- cleanup (trays -> container; Item/Config persistent) ----
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-020';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-TEST', N'Phase6 assembly test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
-- ContainerTray_Close now consumes BOM components; give the test container a 1-line BOM + a component to stage.
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-CHILD', N'Phase6 assembly test component', 1, @Now, 1);
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Item, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
-- ContainerTray_Close now requires open input parts staged at the cell to cover the trays
-- (the routed machined material). Stage a cleanable open LOT at the cell (no child rows).
DELETE FROM Lots.Lot WHERE LotName = N'STG-020';
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-020', @Child, 1, 1, 100000, @Cell, 1);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- tray 1 ByCount (25 == PartsPerTray)
DECLARE @C1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @C1 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 25, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C1);
DECLARE @Tid1 BIGINT = (SELECT NewId FROM @C1);
DECLARE @Acc1 NVARCHAR(10) = (SELECT CAST(ContainerAccumulatedParts AS NVARCHAR(10)) FROM @C1);
EXEC test.Assert_IsEqual @TestName = N'[Tray] ByCount close Status 1', @Expected = N'1', @Actual = @S1;
EXEC test.Assert_IsEqual @TestName = N'[Tray] accumulated 25 after tray 1', @Expected = N'25', @Actual = @Acc1;
DECLARE @CM1 NVARCHAR(20) = (SELECT ClosureMethod FROM Lots.ContainerTray WHERE Id = @Tid1);
EXEC test.Assert_IsEqual @TestName = N'[Tray] ClosureMethod derived from config (ByVision), passed value ignored', @Expected = N'ByVision', @Actual = @CM1;
DECLARE @Aud1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'TrayClosed' AND ol.EntityId = @Tid1);
EXEC test.Assert_IsEqual @TestName = N'[Tray] TrayClosed audit in OperationLog', @Expected = N'1', @Actual = @Aud1;

-- tray 2 ByWeight
DECLARE @C2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @C2 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 2, @PartsCount = 25, @ClosureMethod = N'ByWeight', @AppUserId = 1;
DECLARE @Acc2 NVARCHAR(10) = (SELECT CAST(ContainerAccumulatedParts AS NVARCHAR(10)) FROM @C2);
EXEC test.Assert_IsEqual @TestName = N'[Tray] accumulated 50 after tray 2 (ByWeight)', @Expected = N'50', @Actual = @Acc2;

-- tray 3 ByVision
DECLARE @C3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @C3 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 3, @PartsCount = 25, @ClosureMethod = N'ByVision', @AppUserId = 1;
DECLARE @Acc3 NVARCHAR(10) = (SELECT CAST(ContainerAccumulatedParts AS NVARCHAR(10)) FROM @C3);
EXEC test.Assert_IsEqual @TestName = N'[Tray] accumulated 75 after tray 3 (ByVision)', @Expected = N'75', @Actual = @Acc3;

-- mismatched count rejects
DECLARE @C4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @C4 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 4, @PartsCount = 10, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C4);
EXEC test.Assert_IsEqual @TestName = N'[Tray] mismatched count rejects (Status 0)', @Expected = N'0', @Actual = @S4;

-- re-close position 1 rejects
DECLARE @C5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @C5 EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 25, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C5);
EXEC test.Assert_IsEqual @TestName = N'[Tray] re-close position rejects (Status 0)', @Expected = N'0', @Actual = @S5;
GO

DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-020';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
