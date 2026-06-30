-- =============================================
-- File:         0028_PlantFloor_Assembly/040_Container_Complete_happy.sql
-- Description:  Lots.Container_Complete happy path (Arc 2 Phase 6). Full container +
--               healthy AIM pool -> claim succeeds, ShippingLabel inserted, status
--               flips to Complete, pool row consumed, ContainerCompleted audit.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/040_Container_Complete_happy.sql';
GO

DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-ASM-TEST';
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-040';
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
DELETE FROM Lots.Lot WHERE LotName = N'STG-040';
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-040', @Child, 1, 1, 100000, @Cell, 1);
DECLARE @Tpc INT = (SELECT TraysPerContainer FROM Parts.ContainerConfig WHERE Id = @Config);
DECLARE @Ppt INT = (SELECT PartsPerTray FROM Parts.ContainerConfig WHERE Id = @Config);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- fill every tray
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
DECLARE @t INT = 1;
WHILE @t <= @Tpc
BEGIN
    INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = @t, @PartsCount = @Ppt, @ClosureMethod = N'ByVision', @AppUserId = 1;
    DELETE FROM @TC;
    SET @t = @t + 1;
END

-- seed the AIM pool for this part
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-ASM-TEST', @AimShipperId = N'AIM-CMP-1'; DELETE FROM @TP;
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-ASM-TEST', @AimShipperId = N'AIM-CMP-2';

-- complete
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @Slid BIGINT = (SELECT ShippingLabelId FROM @R);
DECLARE @Aim NVARCHAR(50) = (SELECT AimShipperId FROM @R);
DECLARE @SlidStr NVARCHAR(20) = CAST(@Slid AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Complete] Status is 1', @Expected = N'1', @Actual = @S;
EXEC test.Assert_IsNotNull @TestName = N'[Complete] ShippingLabelId returned', @Value = @SlidStr;
EXEC test.Assert_IsEqual @TestName = N'[Complete] AIM is FIFO first (AIM-CMP-1)', @Expected = N'AIM-CMP-1', @Actual = @Aim;

DECLARE @StatusCode NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Complete] container status flips to Complete (2)', @Expected = N'2', @Actual = @StatusCode;
DECLARE @CompletedSet NVARCHAR(10) = (SELECT CASE WHEN CompletedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Complete] CompletedAt set', @Expected = N'1', @Actual = @CompletedSet;

DECLARE @LabelOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE Id = @Slid AND ContainerId = @Cid AND AimShipperId = @Aim AND IsVoid = 0);
EXEC test.Assert_IsEqual @TestName = N'[Complete] ShippingLabel row created', @Expected = N'1', @Actual = @LabelOk;
DECLARE @PoolConsumed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.AimShipperIdPool WHERE AimShipperId = @Aim AND ConsumedByContainerId = @Cid AND ConsumedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[Complete] AIM pool row consumed by container', @Expected = N'1', @Actual = @PoolConsumed;
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'ContainerCompleted' AND ol.EntityId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Complete] ContainerCompleted audit in OperationLog', @Expected = N'1', @Actual = @Aud;
GO

DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-ASM-TEST';
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-040';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
