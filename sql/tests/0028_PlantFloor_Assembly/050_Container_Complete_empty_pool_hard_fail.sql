-- =============================================
-- File:         0028_PlantFloor_Assembly/050_Container_Complete_empty_pool_hard_fail.sql
-- Description:  Lots.Container_Complete with an EMPTY AIM pool (OI-33 default). The
--               full container is left OPEN (no status flip, no label), Status 0 with
--               an operator-facing empty-pool message. No ROLLBACK (pre-tran reject).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/050_Container_Complete_empty_pool_hard_fail.sql';
GO

DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-ASM-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-050';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-TEST', N'Phase6 assembly test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
-- ContainerTray_Close now requires open input parts staged at the cell to cover the trays
-- (the routed machined material). Stage a cleanable open LOT at the cell (no child rows).
DELETE FROM Lots.Lot WHERE LotName = N'STG-050';
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
    VALUES (N'STG-050', @Item, 1, 1, 100000, @Cell, 1);
DECLARE @Tpc INT = (SELECT TraysPerContainer FROM Parts.ContainerConfig WHERE Id = @Config);
DECLARE @Ppt INT = (SELECT PartsPerTray FROM Parts.ContainerConfig WHERE Id = @Config);

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

-- pool is empty for this part (cleanup deleted it; no topup) -> complete must hard-fail
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CompleteEmpty] Status is 0 (hard-fail)', @Expected = N'0', @Actual = @S;
DECLARE @Mok NVARCHAR(10) = CASE WHEN @M LIKE N'%pool is empty%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CompleteEmpty] message says pool empty', @Expected = N'1', @Actual = @Mok;

DECLARE @StatusCode NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteEmpty] container stays Open (1)', @Expected = N'1', @Actual = @StatusCode;
DECLARE @CompNull NVARCHAR(10) = (SELECT CASE WHEN CompletedAt IS NULL THEN N'1' ELSE N'0' END FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteEmpty] CompletedAt still NULL', @Expected = N'1', @Actual = @CompNull;
DECLARE @NoLabel NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE ContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteEmpty] no ShippingLabel created', @Expected = N'0', @Actual = @NoLabel;
GO

DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-ASM-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE LotName = N'STG-050';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
