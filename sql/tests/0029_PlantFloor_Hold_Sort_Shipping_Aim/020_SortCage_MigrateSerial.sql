-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/020_SortCage_MigrateSerial.sql
-- Description:  Lots.SortCage_MigrateSerial (Arc 2 Phase 7 / UJ-05). Update-in-place
--               migration writes a ContainerSerialHistory row + repoints
--               ContainerSerial.ContainerId; a non-open destination rejects.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/020_SortCage_MigrateSerial.sql';
GO

DELETE csh FROM Lots.ContainerSerialHistory csh INNER JOIN Lots.ContainerSerial cs ON cs.Id = csh.ContainerSerialId INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
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
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- container A (source), container B (open dest), a producing LOT + a serial placed in A
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1; DECLARE @ConA BIGINT = (SELECT NewId FROM @O); DELETE FROM @O;
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1; DECLARE @ConB BIGINT = (SELECT NewId FROM @O);
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 5, @AppUserId = 1, @LotName = N'P7T-SC-LOT'; DECLARE @Lot BIGINT = (SELECT NewId FROM @CL);
DECLARE @M TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1; DECLARE @Sp BIGINT = (SELECT NewId FROM @M);
DECLARE @A TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A EXEC Lots.ContainerSerial_Add @ContainerId = @ConA, @SerializedPartId = @Sp, @AppUserId = 1; DECLARE @Cs BIGINT = (SELECT NewId FROM @A);

-- migrate serial A -> B (open)
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.SortCage_MigrateSerial @ContainerSerialId = @Cs, @NewContainerId = @ConB, @NewTrayPosition = 2, @AppUserId = 2;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @Hid BIGINT = (SELECT NewId FROM @R);
DECLARE @HidStr NVARCHAR(20) = CAST(@Hid AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[SortCage] migrate Status 1', @Expected = N'1', @Actual = @S;
EXEC test.Assert_IsNotNull @TestName = N'[SortCage] history NewId returned', @Value = @HidStr;
DECLARE @NowCon NVARCHAR(20) = (SELECT CAST(ContainerId AS NVARCHAR(20)) FROM Lots.ContainerSerial WHERE Id = @Cs);
DECLARE @ConBStr NVARCHAR(20) = CAST(@ConB AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[SortCage] ContainerSerial repointed to dest', @Expected = @ConBStr, @Actual = @NowCon;
DECLARE @HistOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ContainerSerialHistory WHERE Id = @Hid AND ContainerSerialId = @Cs AND OldContainerId = @ConA AND NewContainerId = @ConB);
EXEC test.Assert_IsEqual @TestName = N'[SortCage] history row captures old/new container', @Expected = N'1', @Actual = @HistOk;

-- migrate into a NON-open (Complete) container rejects
UPDATE Lots.Container SET ContainerStatusCodeId = 2 WHERE Id = @ConA;  -- mark A Complete
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Lots.SortCage_MigrateSerial @ContainerSerialId = @Cs, @NewContainerId = @ConA, @AppUserId = 2;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[SortCage] non-open destination rejects (Status 0)', @Expected = N'0', @Actual = @S2;
GO

DELETE csh FROM Lots.ContainerSerialHistory csh INNER JOIN Lots.ContainerSerial cs ON cs.Id = csh.ContainerSerialId INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
