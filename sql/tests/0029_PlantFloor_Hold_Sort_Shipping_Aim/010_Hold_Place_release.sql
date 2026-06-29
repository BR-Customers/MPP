-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/010_Hold_Place_release.sql
-- Description:  Quality.Hold_Place / Hold_Release (Arc 2 Phase 7 / FDS-08-007a).
--               LOT hold -> status Hold(2) + B3 double-place rejects + GetOpenByLot +
--               release restores prior status. Container hold -> status Hold(4) ->
--               release -> Complete(2).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/010_Hold_Place_release.sql';
GO

-- ---- cleanup (HoldEvent -> Container/LOT; reuse the P6-ASM-TEST item/config) ----
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT l.Id FROM Lots.Lot l INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST')
   OR ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P6-ASM-TEST');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-TEST', N'Phase6 assembly test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @HoldType BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @LotName = N'P7T-HOLD-LOT';
DECLARE @Lot BIGINT = (SELECT NewId FROM @CL);
DECLARE @CO TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @CO EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Con BIGINT = (SELECT NewId FROM @CO);

-- place hold on the LOT
DECLARE @P1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @P1 EXEC Quality.Hold_Place @LotId = @Lot, @HoldTypeCodeId = @HoldType, @Reason = N'Test hold', @AppUserId = 2;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @P1);
DECLARE @He1 BIGINT = (SELECT NewId FROM @P1);
EXEC test.Assert_IsEqual @TestName = N'[Hold] LOT hold placed (Status 1)', @Expected = N'1', @Actual = @S1;
DECLARE @LotStat NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Hold] LOT status -> Hold (2)', @Expected = N'2', @Actual = @LotStat;
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'HoldPlaced' AND ol.EntityId = @He1);
EXEC test.Assert_IsEqual @TestName = N'[Hold] HoldPlaced audit in OperationLog', @Expected = N'1', @Actual = @Aud;

-- B3: double-place rejects
DECLARE @P2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @P2 EXEC Quality.Hold_Place @LotId = @Lot, @HoldTypeCodeId = @HoldType, @AppUserId = 2;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @P2);
EXEC test.Assert_IsEqual @TestName = N'[Hold] double-place on LOT rejects (B3)', @Expected = N'0', @Actual = @S2;

-- GetOpenByLot returns it
DECLARE @G TABLE (Id BIGINT, LotId BIGINT, ContainerId BIGINT, HoldTypeCodeId BIGINT, HoldTypeCode NVARCHAR(50), Reason NVARCHAR(500), PlacedByUserId BIGINT, PlacedAt DATETIME2(3));
INSERT INTO @G EXEC Quality.Hold_GetOpenByLot @LotId = @Lot;
DECLARE @GC NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Hold] GetOpenByLot returns the open hold', @Expected = N'1', @Actual = @GC;

-- release the LOT hold -> restores Good (1)
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Quality.Hold_Release @HoldEventId = @He1, @ReleaseRemarks = N'cleared', @AppUserId = 2;
DECLARE @RS1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[Hold] LOT hold released (Status 1)', @Expected = N'1', @Actual = @RS1;
DECLARE @LotStat2 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Hold] LOT status restored to Good (1)', @Expected = N'1', @Actual = @LotStat2;

-- place + release hold on the CONTAINER.
-- P7-7: Hold_Release restores the container's PRIOR status (captured at place
-- time), not a hardcoded Complete. Put the container in Complete (2) first so
-- the realistic "hold a completed container, then release it" path restores
-- back to Complete.
UPDATE Lots.Container SET ContainerStatusCodeId = 2 WHERE Id = @Con;  -- 2 = Complete
DECLARE @P3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @P3 EXEC Quality.Hold_Place @ContainerId = @Con, @HoldTypeCodeId = @HoldType, @AppUserId = 2;
DECLARE @He3 BIGINT = (SELECT NewId FROM @P3);
DECLARE @ConStat NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Hold] container hold -> status Hold (4)', @Expected = N'4', @Actual = @ConStat;
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Quality.Hold_Release @HoldEventId = @He3, @AppUserId = 2;
DECLARE @ConStat2 NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Hold] container hold released -> restored to prior Complete (2)', @Expected = N'2', @Actual = @ConStat2;

-- P7-7 regression: a SHIPPED (3) container held for a recall and then released
-- must return to Shipped, NOT a re-shippable Complete (which would let
-- Container_Ship double-ship it).
UPDATE Lots.Container SET ContainerStatusCodeId = 3 WHERE Id = @Con;  -- 3 = Shipped
DECLARE @P4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @P4 EXEC Quality.Hold_Place @ContainerId = @Con, @HoldTypeCodeId = @HoldType, @AppUserId = 2;
DECLARE @He4 BIGINT = (SELECT NewId FROM @P4);
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R3 EXEC Quality.Hold_Release @HoldEventId = @He4, @AppUserId = 2;
DECLARE @ConStat3 NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Hold] P7-7: shipped container hold released -> restored to Shipped (3)', @Expected = N'3', @Actual = @ConStat3;
GO

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT l.Id FROM Lots.Lot l INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST')
   OR ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P6-ASM-TEST');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
