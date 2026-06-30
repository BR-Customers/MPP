-- =============================================
-- File:         0028_PlantFloor_Assembly/030_ContainerSerial_Add_with_bypass.sql
-- Description:  Lots.ContainerSerial_Add (Arc 2 Phase 6). Places minted serials in
--               a container; HardwareInterlockBypassed=1 recorded (UJ-16); a serial
--               is placed at most once (re-add rejects); ContainerSerialAdded audit.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/030_ContainerSerial_Add_with_bypass.sql';
GO

-- ---- cleanup (FK-safe; Item/Config persistent) ----
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.Container ct ON ct.Id = cs.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
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

-- container + producing LOT + two minted serials
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @LotName = N'P6T-ASM-LOT';
DECLARE @Lot BIGINT = (SELECT NewId FROM @CL);

DECLARE @M1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M1 EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1;
DECLARE @Sp1 BIGINT = (SELECT NewId FROM @M1);
DECLARE @M2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M2 EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1;
DECLARE @Sp2 BIGINT = (SELECT NewId FROM @M2);

-- add serial 1 WITH interlock bypass
DECLARE @A1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A1 EXEC Lots.ContainerSerial_Add @ContainerId = @Cid, @SerializedPartId = @Sp1, @HardwareInterlockBypassed = 1, @AppUserId = 1;
DECLARE @AS1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A1);
DECLARE @ACid BIGINT = (SELECT NewId FROM @A1);
DECLARE @ACidStr NVARCHAR(20) = CAST(@ACid AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[SerialAdd] serial 1 added, Status 1', @Expected = N'1', @Actual = @AS1;
EXEC test.Assert_IsNotNull @TestName = N'[SerialAdd] ContainerSerial NewId returned', @Value = @ACidStr;

DECLARE @Byp NVARCHAR(10) = (SELECT CAST(HardwareInterlockBypassed AS NVARCHAR(10)) FROM Lots.ContainerSerial WHERE Id = @ACid);
EXEC test.Assert_IsEqual @TestName = N'[SerialAdd] HardwareInterlockBypassed recorded =1', @Expected = N'1', @Actual = @Byp;

DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'ContainerSerialAdded' AND ol.EntityId = @ACid);
EXEC test.Assert_IsEqual @TestName = N'[SerialAdd] ContainerSerialAdded audit in OperationLog', @Expected = N'1', @Actual = @Aud;

-- add serial 2 normally
DECLARE @A2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A2 EXEC Lots.ContainerSerial_Add @ContainerId = @Cid, @SerializedPartId = @Sp2, @HardwareInterlockBypassed = 0, @AppUserId = 1;
DECLARE @AS2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A2);
EXEC test.Assert_IsEqual @TestName = N'[SerialAdd] serial 2 added, Status 1', @Expected = N'1', @Actual = @AS2;

-- exactly one bypassed serial in the container
DECLARE @BypCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ContainerSerial WHERE ContainerId = @Cid AND HardwareInterlockBypassed = 1);
EXEC test.Assert_IsEqual @TestName = N'[SerialAdd] exactly one bypassed serial in container', @Expected = N'1', @Actual = @BypCnt;

-- re-add serial 1 rejects (placed at most once)
DECLARE @A3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A3 EXEC Lots.ContainerSerial_Add @ContainerId = @Cid, @SerializedPartId = @Sp1, @HardwareInterlockBypassed = 0, @AppUserId = 1;
DECLARE @AS3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A3);
EXEC test.Assert_IsEqual @TestName = N'[SerialAdd] re-add of placed serial rejects (Status 0)', @Expected = N'0', @Actual = @AS3;
GO

-- ---- cleanup ----
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.Container ct ON ct.Id = cs.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
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
