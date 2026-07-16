-- =============================================
-- File: 0038_PlcIntegration/040_SerializedPart_serial.sql
-- Tests SerializedPart_Mint with a supplied serial + auto-gen + GetBySerial.
-- Self-contained: creates a throwaway Item + producing LOT (via Lot_Create,
-- mirroring 0028/030's fixture) since a clean reset seeds no LOTs. Tears down
-- FK-safe: SerializedPart -> LotGenealogyClosure self-row -> Lot -> ItemLocation
-- -> Item. Assertion @Actual values are precomputed into @vars.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0038_PlcIntegration/040_SerializedPart_serial.sql';
GO

-- Fixture: throwaway Item + eligibility + a Manufactured LOT at a seed cell.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @Uom   BIGINT = (SELECT TOP 1 Id FROM Parts.Uom WHERE DeprecatedAt IS NULL ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'PLC-SN-TEST', N'PLC serial test part', @Uom, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@Item AND LocationId=@Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
IF NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT')
BEGIN
    DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
    INSERT INTO @CL EXEC Lots.Lot_Create @ItemId=@Item, @LotOriginTypeId=@OriginMfg,
        @CurrentLocationId=@Cell, @PieceCount=10, @AppUserId=1, @LotName=N'PLC-SN-TEST-LOT';
END
GO

-- Test 1: mint with a supplied serial
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT, @Serial NVARCHAR(50);
DECLARE @itemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST');
DECLARE @lotId BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO #R1 EXEC Lots.SerializedPart_Mint @ItemId=@itemId, @ProducingLotId=@lotId,
    @AppUserId=1, @SerialNumber=N'TESTSN-000001';
SELECT @S=Status, @M=Message, @NewId=NewId, @Serial=SerialNumber FROM #R1; DROP TABLE #R1;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Mint supplied serial: status 1', @Expected=N'1', @Actual=@SStr;
EXEC test.Assert_IsEqual @TestName=N'Mint supplied serial: serial echoed',
    @Expected=N'TESTSN-000001', @Actual=@Serial;
GO

-- Test 2: duplicate supplied serial rejected
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @itemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST');
DECLARE @lotId BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO #R2 EXEC Lots.SerializedPart_Mint @ItemId=@itemId, @ProducingLotId=@lotId,
    @AppUserId=1, @SerialNumber=N'TESTSN-000001';
SELECT @S=Status, @M=Message FROM #R2; DROP TABLE #R2;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Mint dup serial: status 0', @Expected=N'0', @Actual=@SStr;
EXEC test.Assert_Contains @TestName=N'Mint dup serial: message mentions exists',
    @HaystackStr=@M, @NeedleStr=N'already';
GO

-- Test 3: auto-gen when @SerialNumber NULL (existing behavior preserved)
DECLARE @S BIT, @Serial NVARCHAR(50);
DECLARE @itemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST');
DECLARE @lotId BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO #R3 EXEC Lots.SerializedPart_Mint @ItemId=@itemId, @ProducingLotId=@lotId, @AppUserId=1;
SELECT @S=Status, @Serial=SerialNumber FROM #R3; DROP TABLE #R3;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Mint auto-gen: status 1', @Expected=N'1', @Actual=@SStr;
DECLARE @HasSerial NVARCHAR(1) = CASE WHEN @Serial IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'Mint auto-gen: serial generated', @Expected=N'1', @Actual=@HasSerial;
GO

-- Test 4: GetBySerial finds the supplied one
CREATE TABLE #G (Id BIGINT, SerialNumber NVARCHAR(50), ItemId BIGINT, ProducingLotId BIGINT, EtchedAt DATETIME2(3));
INSERT INTO #G EXEC Lots.SerializedPart_GetBySerial @SerialNumber=N'TESTSN-000001';
DECLARE @rc NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #G) AS NVARCHAR(10)); DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetBySerial finds TESTSN-000001', @Expected=N'1', @Actual=@rc;
GO

-- Cleanup (FK-safe): SerializedPart + all Lot_Create side-rows (event log, movement,
-- status history, genealogy closure) -> Lot -> ItemLocation -> Item.
DELETE FROM Lots.SerializedPart     WHERE ProducingLotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
DELETE FROM Lots.LotGenealogyClosure
    WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT')
       OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT');
DELETE FROM Lots.Lot WHERE LotName = N'PLC-SN-TEST-LOT';
DELETE FROM Parts.ItemLocation WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST');
DELETE FROM Parts.Item WHERE PartNumber = N'PLC-SN-TEST';
GO

EXEC test.PrintSummary;
GO
