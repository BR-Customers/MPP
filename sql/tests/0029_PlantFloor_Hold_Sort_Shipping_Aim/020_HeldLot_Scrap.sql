-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/020_HeldLot_Scrap.sql
-- Description:  FAT-QH-150 - scrap directly against a HELD LOT via the canonical
--               Workorder.RejectEvent_Record, gated by @AllowHeldLot. No split, no
--               hold release. The exception is scoped to Hold(2) status ONLY:
--               Scrap(3) / Closed(4) still reject even with @AllowHeldLot=1. A
--               held LOT scrapped to zero stays HELD (the hold lifecycle owns the
--               terminal transition -- close-at-zero is NOT extended to held LOTs).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/020_HeldLot_Scrap.sql';
GO

-- ---- cleanup (RejectEvent -> HoldEvent -> history/closure -> LOT; keyed on the test part) ----
DELETE re FROM Workorder.RejectEvent re INNER JOIN Lots.Lot l ON l.Id = re.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT l.Id FROM Lots.Lot l INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH150-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'F-QH150-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'F-QH150-TEST', N'Held-LOT scrap test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH150-TEST');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @HoldType BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);

-- ============================================================
-- Case 1: held LOT, @AllowHeldLot omitted (default 0) -> rejected, LOT untouched
-- ============================================================
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @LotName = N'QH150-LOT-A';
DECLARE @Lot BIGINT = (SELECT NewId FROM @CL);
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @Lot, @HoldTypeCodeId = @HoldType, @Reason = N'QH150 test', @AppUserId = 2;

DECLARE @R0 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R0 EXEC Workorder.RejectEvent_Record @LotId = @Lot, @DefectCodeId = @Defect, @Quantity = 3, @AppUserId = 2;
DECLARE @S0 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R0);
DECLARE @PC0 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[QH150] held LOT, AllowHeldLot=0 -> reject (Status 0)', @Expected = N'0', @Actual = @S0;
EXEC test.Assert_IsEqual @TestName = N'[QH150] AllowHeldLot=0 leaves PieceCount unchanged (10)', @Expected = N'10', @Actual = @PC0;

-- ============================================================
-- Case 2: held LOT, @AllowHeldLot=1, partial scrap -> Status 1, decremented, still HELD
-- ============================================================
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Workorder.RejectEvent_Record @LotId = @Lot, @DefectCodeId = @Defect, @Quantity = 3, @AppUserId = 2, @AllowHeldLot = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
DECLARE @RC1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId = @Lot);
DECLARE @PC1 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @ST1 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @HC1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.HoldEvent WHERE LotId = @Lot AND ReleasedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[QH150] held LOT scrap AllowHeldLot=1 (Status 1)', @Expected = N'1', @Actual = @S1;
EXEC test.Assert_IsEqual @TestName = N'[QH150] one RejectEvent row written', @Expected = N'1', @Actual = @RC1;
EXEC test.Assert_IsEqual @TestName = N'[QH150] PieceCount decremented 10 -> 7', @Expected = N'7', @Actual = @PC1;
EXEC test.Assert_IsEqual @TestName = N'[QH150] LOT stays HELD after partial scrap (status 2)', @Expected = N'2', @Actual = @ST1;
EXEC test.Assert_IsEqual @TestName = N'[QH150] hold still open after scrap', @Expected = N'1', @Actual = @HC1;

-- ============================================================
-- Case 3: scrap ALL remaining -> Status 1, PieceCount 0, LOT STILL HELD (not auto-closed)
-- ============================================================
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Workorder.RejectEvent_Record @LotId = @Lot, @DefectCodeId = @Defect, @Quantity = 7, @AppUserId = 2, @AllowHeldLot = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
DECLARE @PC2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @ST2 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[QH150] scrap-all AllowHeldLot=1 (Status 1)', @Expected = N'1', @Actual = @S2;
EXEC test.Assert_IsEqual @TestName = N'[QH150] PieceCount driven to 0', @Expected = N'0', @Actual = @PC2;
EXEC test.Assert_IsEqual @TestName = N'[QH150] fully-scrapped held LOT stays HELD, NOT Closed (status 2)', @Expected = N'2', @Actual = @ST2;

-- ============================================================
-- Case 4: AllowHeldLot=1 does NOT let a Scrap(3) LOT be rejected (Hold-only exception)
-- ============================================================
DECLARE @CL2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL2 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 5, @AppUserId = 1, @LotName = N'QH150-LOT-SCRAP';
DECLARE @LotS BIGINT = (SELECT NewId FROM @CL2);
UPDATE Lots.Lot SET LotStatusId = 3 WHERE Id = @LotS;  -- 3 = Scrap (BlocksProduction=1)
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R3 EXEC Workorder.RejectEvent_Record @LotId = @LotS, @DefectCodeId = @Defect, @Quantity = 1, @AppUserId = 2, @AllowHeldLot = 1;
DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[QH150] AllowHeldLot=1 still rejects a Scrap(3) LOT', @Expected = N'0', @Actual = @S3;

-- ============================================================
-- Case 5: AllowHeldLot=1 does NOT let a Closed(4) LOT be rejected
-- ============================================================
UPDATE Lots.Lot SET LotStatusId = 4 WHERE Id = @LotS;  -- 4 = Closed
DECLARE @R4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R4 EXEC Workorder.RejectEvent_Record @LotId = @LotS, @DefectCodeId = @Defect, @Quantity = 1, @AppUserId = 2, @AllowHeldLot = 1;
DECLARE @S4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R4);
EXEC test.Assert_IsEqual @TestName = N'[QH150] AllowHeldLot=1 still rejects a Closed(4) LOT', @Expected = N'0', @Actual = @S4;

-- ============================================================
-- Case 6: existing validations still fire under AllowHeldLot=1 (qty<=0 rejects)
-- ============================================================
DECLARE @R5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R5 EXEC Workorder.RejectEvent_Record @LotId = @Lot, @DefectCodeId = @Defect, @Quantity = 0, @AppUserId = 2, @AllowHeldLot = 1;
DECLARE @S5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R5);
EXEC test.Assert_IsEqual @TestName = N'[QH150] qty<=0 still rejects under AllowHeldLot=1', @Expected = N'0', @Actual = @S5;
GO

-- ---- teardown ----
DELETE re FROM Workorder.RejectEvent re INNER JOIN Lots.Lot l ON l.Id = re.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT l.Id FROM Lots.Lot l INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH150-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH150-TEST');
GO

EXEC test.EndTestFile;
GO
