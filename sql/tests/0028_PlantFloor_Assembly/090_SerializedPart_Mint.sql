-- =============================================
-- File:         0028_PlantFloor_Assembly/090_SerializedPart_Mint.sql
-- Description:  Lots.SerializedPart_Mint (Arc 2 Phase 6). Mints a laser-etched
--               part: SerialNumber from the 'SerializedItem' sequence (MESI{0:D7}),
--               unique + incrementing; ItemId/ProducingLotId persisted.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/090_SerializedPart_Mint.sql';
GO

-- ---- cleanup (FK-safe: ContainerSerial -> SerializedPart; LOT children -> LOT) ----
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
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
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @LotName = N'P6T-ASM-LOT';
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

-- mint serial 1
DECLARE @M1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M1 EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M1);
DECLARE @Ser1 NVARCHAR(50) = (SELECT SerialNumber FROM @M1);
DECLARE @Id1 NVARCHAR(20) = (SELECT CAST(NewId AS NVARCHAR(20)) FROM @M1);
EXEC test.Assert_IsEqual @TestName = N'[Mint] Status is 1', @Expected = N'1', @Actual = @S1;
EXEC test.Assert_IsNotNull @TestName = N'[Mint] NewId returned', @Value = @Id1;
DECLARE @SerPrefixOk NVARCHAR(10) = CASE WHEN @Ser1 LIKE N'MESI%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Mint] SerialNumber has MESI prefix', @Expected = N'1', @Actual = @SerPrefixOk;
DECLARE @SerLen NVARCHAR(10) = CAST(LEN(@Ser1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Mint] SerialNumber is MESI + 7 digits (len 11)', @Expected = N'11', @Actual = @SerLen;

-- row persisted with the right Item + producing LOT
DECLARE @RowOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.SerializedPart WHERE SerialNumber = @Ser1 AND ItemId = @Item AND ProducingLotId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Mint] SerializedPart row persisted (Item + producing LOT)', @Expected = N'1', @Actual = @RowOk;

-- mint serial 2 -> distinct + incrementing
DECLARE @M2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M2 EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1;
DECLARE @Ser2 NVARCHAR(50) = (SELECT SerialNumber FROM @M2);
DECLARE @Distinct NVARCHAR(10) = CASE WHEN @Ser2 <> @Ser1 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Mint] second serial distinct from first', @Expected = N'1', @Actual = @Distinct;
GO

-- ---- cleanup ----
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P6-ASM-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
