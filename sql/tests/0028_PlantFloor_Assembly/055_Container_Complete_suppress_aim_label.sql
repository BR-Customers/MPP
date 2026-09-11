-- =============================================
-- File:         0028_PlantFloor_Assembly/055_Container_Complete_suppress_aim_label.sql
-- Description:  Lots.Container_Complete v1.2 with the terminal attribute
--               SuppressAimAndLabel (Migration 0079; parallel run beside legacy).
--                 A. '1' + EMPTY pool      -> completes (no OI-33 hard-fail), no
--                    ShippingLabel, NULL ShippingLabelId/AimShipperId, audit says so.
--                 B. '1' + a pool row      -> completes, the pool row is NOT consumed.
--                 C. '0' + the same row    -> normal path: claims it + writes a label.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/055_Container_Complete_suppress_aim_label.sql';
GO

-- ---- cleanup (containers + the SuppressAimAndLabel attribute we manage) ----
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
    WHERE lad.AttributeName = N'SuppressAimAndLabel';
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-055';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

-- ---- the definition exists (Migration 0079) ----
DECLARE @DefRow NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'SuppressAimAndLabel' AND DataType = N'BIT' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Suppress] 0079 terminal attribute definition exists (BIT)', @Expected = N'1', @Actual = @DefRow;
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-TEST', N'Phase6 assembly test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
-- ContainerTray_Close consumes BOM components; give the test container a 1-line BOM + a component to stage.
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-CHILD', N'Phase6 assembly test component', 1, @Now, 1);
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Item, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END
DECLARE @Tpc INT = (SELECT TraysPerContainer FROM Parts.ContainerConfig WHERE Id = @Config);
DECLARE @Ppt INT = (SELECT PartsPerTray FROM Parts.ContainerConfig WHERE Id = @Config);

-- a terminal (its type carries the SuppressAimAndLabel definition), used as cell + terminal
DECLARE @Cell BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationAttributeDefinition lad ON lad.LocationTypeDefinitionId = l.LocationTypeDefinitionId
    WHERE lad.AttributeName = N'SuppressAimAndLabel' AND lad.DeprecatedAt IS NULL AND l.DeprecatedAt IS NULL
    ORDER BY l.Id);
DECLARE @DefId BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'SuppressAimAndLabel' AND DeprecatedAt IS NULL);
-- RequiresCompletionConfirm may be set on this terminal by seed data; confirm every call.

DELETE FROM Lots.Lot WHERE LotName = N'STG-055';
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-055', @Child, 1, 1, 100000, @Cell, 1);

DECLARE @O  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @R  TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @Cid BIGINT, @t INT, @v NVARCHAR(500);

-- ============ A. suppressed + EMPTY pool ============
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
VALUES (@Cell, @DefId, N'1', @Now);

INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
SET @Cid = (SELECT NewId FROM @O); DELETE FROM @O;
SET @t = 1;
WHILE @t <= @Tpc
BEGIN
    INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = @t, @PartsCount = @Ppt, @ClosureMethod = N'ByVision', @AppUserId = 1;
    DELETE FROM @TC;
    SET @t = @t + 1;
END

INSERT INTO @R EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
SET @v = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] empty pool still completes (Status 1)', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CASE WHEN ShippingLabelId IS NULL AND AimShipperId IS NULL THEN N'1' ELSE N'0' END FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] returns NULL ShippingLabelId + AimShipperId', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CASE WHEN Message LIKE N'%suppressed%' THEN N'1' ELSE N'0' END FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] message says suppressed', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] container Complete (2)', @Expected = N'2', @Actual = @v;
SET @v = (SELECT CASE WHEN CompletedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] CompletedAt stamped', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE ContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] no ShippingLabel row', @Expected = N'0', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
          WHERE et.Code = N'ContainerCompleted' AND ol.EntityId = @Cid AND ol.Description LIKE N'%suppressed%');
EXEC test.Assert_IsEqual @TestName = N'[Suppress A] ContainerCompleted audit notes the suppression', @Expected = N'1', @Actual = @v;
DELETE FROM @R;

-- ============ B. suppressed + a pool row: the row stays unconsumed ============
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-SUP-1';
DELETE FROM @TP;

INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
SET @Cid = (SELECT NewId FROM @O); DELETE FROM @O;
SET @t = 1;
WHILE @t <= @Tpc
BEGIN
    INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = @t, @PartsCount = @Ppt, @ClosureMethod = N'ByVision', @AppUserId = 1;
    DELETE FROM @TC;
    SET @t = @t + 1;
END

INSERT INTO @R EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
SET @v = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Suppress B] completes with a pool row available (Status 1)', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CASE WHEN ConsumedAt IS NULL AND ConsumedByContainerId IS NULL THEN N'1' ELSE N'0' END
          FROM Lots.AimShipperIdPool WHERE AimShipperId = N'AIM-SUP-1');
EXEC test.Assert_IsEqual @TestName = N'[Suppress B] pool row NOT consumed', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE ContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Suppress B] no ShippingLabel row', @Expected = N'0', @Actual = @v;
DELETE FROM @R;

-- ============ C. attribute '0' -> the normal path claims + labels ============
UPDATE Location.LocationAttribute SET AttributeValue = N'0' WHERE LocationId = @Cell AND LocationAttributeDefinitionId = @DefId;

INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
SET @Cid = (SELECT NewId FROM @O); DELETE FROM @O;
SET @t = 1;
WHILE @t <= @Tpc
BEGIN
    INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = @t, @PartsCount = @Ppt, @ClosureMethod = N'ByVision', @AppUserId = 1;
    DELETE FROM @TC;
    SET @t = @t + 1;
END

INSERT INTO @R EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
SET @v = (SELECT AimShipperId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Suppress C] attribute 0 claims the pool row', @Expected = N'AIM-SUP-1', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE ContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Suppress C] attribute 0 writes the ShippingLabel', @Expected = N'1', @Actual = @v;
GO

-- ---- cleanup ----
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
    WHERE lad.AttributeName = N'SuppressAimAndLabel';
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-055';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
