-- =============================================
-- File:         0028_PlantFloor_Assembly/060_Container_Complete_with_completion_confirm.sql
-- Description:  Lots.Container_Complete OI-16 gate. With RequiresCompletionConfirm=true
--               on the terminal, @OperatorConfirmed=0 rejects (container stays Open);
--               @OperatorConfirmed=1 completes. Uses a cell whose type carries the
--               RequiresCompletionConfirm attribute definition.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/060_Container_Complete_with_completion_confirm.sql';
GO

-- ---- cleanup (containers + the RequiresCompletionConfirm override we manage) ----
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-ASM-TEST';
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-060';
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
DECLARE @Tpc INT = (SELECT TraysPerContainer FROM Parts.ContainerConfig WHERE Id = @Config);
DECLARE @Ppt INT = (SELECT PartsPerTray FROM Parts.ContainerConfig WHERE Id = @Config);

-- a cell whose type carries the RequiresCompletionConfirm attribute definition
DECLARE @Cell BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationAttributeDefinition lad ON lad.LocationTypeDefinitionId = l.LocationTypeDefinitionId
    WHERE lad.AttributeName = N'RequiresCompletionConfirm' AND lad.DeprecatedAt IS NULL AND l.DeprecatedAt IS NULL
    ORDER BY l.Id);
DECLARE @DefId BIGINT = (SELECT TOP 1 lad.Id FROM Location.LocationAttributeDefinition lad
    INNER JOIN Location.Location l ON l.LocationTypeDefinitionId = lad.LocationTypeDefinitionId
    WHERE l.Id = @Cell AND lad.AttributeName = N'RequiresCompletionConfirm' AND lad.DeprecatedAt IS NULL);

-- set RequiresCompletionConfirm = true on this terminal
DELETE FROM Location.LocationAttribute WHERE LocationId = @Cell AND LocationAttributeDefinitionId = @DefId;
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
VALUES (@Cell, @DefId, N'true', @Now);

-- ContainerTray_Close requires open input parts staged at the cell (the routed material).
DELETE FROM Lots.Lot WHERE LotName = N'STG-060';
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-060', @Child, 1, 1, 100000, @Cell, 1);
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
DECLARE @t INT = 1;
WHILE @t <= @Tpc
BEGIN
    INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = @t, @PartsCount = @Ppt, @ClosureMethod = N'ByVision', @AppUserId = 1;
    DELETE FROM @TC;
    SET @t = @t + 1;
END

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-ASM-TEST', @AimShipperId = N'AIM-CFM-1';

-- without operator confirm -> reject
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R1 EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 0, @PlcCompletionConfirmed = 0, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteConfirm] unconfirmed rejects (Status 0)', @Expected = N'0', @Actual = @S1;
DECLARE @StillOpen NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteConfirm] container stays Open after reject', @Expected = N'1', @Actual = @StillOpen;

-- with operator confirm -> completes
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R2 EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteConfirm] confirmed completes (Status 1)', @Expected = N'1', @Actual = @S2;
DECLARE @NowComplete NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteConfirm] container Complete (2) after confirm', @Expected = N'2', @Actual = @NowComplete;
GO

-- ---- cleanup (containers + override) ----
DECLARE @Cell2 BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationAttributeDefinition lad ON lad.LocationTypeDefinitionId = l.LocationTypeDefinitionId
    WHERE lad.AttributeName = N'RequiresCompletionConfirm' AND lad.DeprecatedAt IS NULL AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
    WHERE la.LocationId = @Cell2 AND lad.AttributeName = N'RequiresCompletionConfirm' AND la.AttributeValue = N'true';
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-ASM-TEST';
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-060';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
