-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/030_Container_Ship.sql
-- Description:  Lots.Container_Ship (Arc 2 Phase 7). Complete + non-Hold + non-Void
--               ships (status -> Shipped 3); a held container rejects; a void label
--               rejects. Uses a 1x1 container config (target 1) for short fixtures.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/030_Container_Ship.sql';
GO

DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST');
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P7-SHIP-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P7-SHIP-TEST', N'Phase7 ship test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 1, 1, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @HoldType BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P7-SHIP-TEST', @AimShipperId = N'AIM-SH-1'; DELETE FROM @TP;
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P7-SHIP-TEST', @AimShipperId = N'AIM-SH-2'; DELETE FROM @TP;
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P7-SHIP-TEST', @AimShipperId = N'AIM-SH-3';

-- reusable: complete one container, return @Con + @Slid via the last-row temp tables
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));

-- container 1: happy ship
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1; DECLARE @C1 BIGINT = (SELECT NewId FROM @O); DELETE FROM @O;
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @C1, @TrayPosition = 1, @PartsCount = 1, @ClosureMethod = N'ByCount', @AppUserId = 1; DELETE FROM @TC;
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @C1, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell; DECLARE @Slid1 BIGINT = (SELECT ShippingLabelId FROM @CMP); DELETE FROM @CMP;

DECLARE @SH TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @Slid1, @AppUserId = 2, @TerminalLocationId = @Cell;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[Ship] complete container ships (Status 1)', @Expected = N'1', @Actual = @S1;
DECLARE @St1 NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Ship] container -> Shipped (3)', @Expected = N'3', @Actual = @St1;
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'ContainerShipped' AND ol.EntityId = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Ship] ContainerShipped audit in OperationLog', @Expected = N'1', @Actual = @Aud;
-- ship again rejects (no longer Complete)
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @Slid1, @AppUserId = 2; DECLARE @S1b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[Ship] re-ship rejects (not Complete)', @Expected = N'0', @Actual = @S1b;

-- container 2: void label rejects
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1; DECLARE @C2 BIGINT = (SELECT NewId FROM @O); DELETE FROM @O;
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @C2, @TrayPosition = 1, @PartsCount = 1, @ClosureMethod = N'ByCount', @AppUserId = 1; DELETE FROM @TC;
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @C2, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell; DECLARE @Slid2 BIGINT = (SELECT ShippingLabelId FROM @CMP); DELETE FROM @CMP;
DECLARE @V TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V EXEC Lots.ShippingLabel_Void @ShippingLabelId = @Slid2, @VoidReason = N'test', @AppUserId = 2;
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @Slid2, @AppUserId = 2; DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[Ship] void label rejects ship (Status 0)', @Expected = N'0', @Actual = @S2;

-- container 3: held container rejects
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1; DECLARE @C3 BIGINT = (SELECT NewId FROM @O); DELETE FROM @O;
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @C3, @TrayPosition = 1, @PartsCount = 1, @ClosureMethod = N'ByCount', @AppUserId = 1; DELETE FROM @TC;
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @C3, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell; DECLARE @Slid3 BIGINT = (SELECT ShippingLabelId FROM @CMP); DELETE FROM @CMP;
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HP EXEC Quality.Hold_Place @ContainerId = @C3, @HoldTypeCodeId = @HoldType, @AppUserId = 2;
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @Slid3, @AppUserId = 2; DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[Ship] held container rejects ship (Status 0)', @Expected = N'0', @Actual = @S3;
GO

DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST');
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P7-SHIP-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST');
GO

EXEC test.EndTestFile;
GO
