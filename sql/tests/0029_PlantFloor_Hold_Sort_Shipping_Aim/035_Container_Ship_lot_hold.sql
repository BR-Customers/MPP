-- =============================================
-- File: 0029_PlantFloor_Hold_Sort_Shipping_Aim/035_Container_Ship_lot_hold.sql
-- Desc: Lots.Container_Ship v1.1 -- a container does not ship while a LOT packed in
--       it is on hold, even when nobody held the container itself. "Packed in it" is
--       the two paths Quality.Hold_ListAssociatedContainers already uses:
--         A) a finished-good tray LOT (Lots.ContainerTray.FinishedGoodLotId)
--         B) the producing LOT of a serial still in the container
--            (Lots.SerializedPart.ProducingLotId via Lots.ContainerSerial, RemovedAt NULL)
--       Container_Complete is deliberately unchanged: it still completes a container
--       with a held tray (skipping that tray's close), and Quality.Hold_Release closes
--       the tray later (FAT #21). Ship is the only gate.
--
--       Fixture mirrors 0056_CrtValidation/070: the seeded 6NA ContainerConfig is
--       4 trays x 6 parts, closed through Workorder.Assembly_CompleteTray (CRT off), so
--       every tray carries an FG LOT. Two containers; component stock topped up first.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/035_Container_Ship_lot_hold.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

-- ---- teardown (FK-safe order): this file's own FG containers/LOTs only ----
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @TdShip BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPOUT');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip));
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.Container c ON c.Id = cs.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.SerializedPart WHERE ProducingLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @HoldType BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-LOTHOLD-1';
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-LOTHOLD-2';

-- Component stock for 2 containers = 48 FG pieces: 48 x 12270-6NA-M (MaxLotSize 12),
-- 48 x 92900-06014-1B, 96 x 94301-08100, each with a buffer.
DECLARE @CompA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @CompB BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @CompC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');
DECLARE @Stock TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @k INT = 1;
WHILE @k <= 5
BEGIN
    INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
    SET @k = @k + 1;
END
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompB, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 60, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompC, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 120, @AppUserId = 1;

DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @HR TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @SH TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @t INT;
DECLARE @Lot BIGINT;

-- =====================================================================
-- Container A: tray 2's LOT is held BEFORE the container completes
-- =====================================================================
DECLARE @ConA BIGINT, @HeldTrayLot BIGINT;
SET @t = 1;
WHILE @t <= 4
BEGIN
    DELETE FROM @AT;
    INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray
        @FinishedGoodItemId = @Fg, @PieceCount = 6, @CellLocationId = @Cell,
        @ClosureMethod = N'ByVision', @AppUserId = 1, @TerminalLocationId = @Term;
    SET @ConA = (SELECT ContainerId FROM @AT);
    SET @Lot  = (SELECT FinishedGoodLotId FROM @AT);
    IF @t = 2 SET @HeldTrayLot = @Lot;
    SET @t = @t + 1;
END

INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @HeldTrayLot, @HoldTypeCodeId = @HoldType, @Reason = N'test tray hold', @AppUserId = 2;
DECLARE @HoldA BIGINT = (SELECT NewId FROM @HP); DELETE FROM @HP;

INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @ConA, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @CmpA NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CC);
DECLARE @SlidA BIGINT = (SELECT ShippingLabelId FROM @CC); DELETE FROM @CC;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] container with a held tray still completes (unchanged)',
    @Expected = N'1', @Actual = @CmpA;

INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @SlidA, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @SA1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH);
DECLARE @MA1 NVARCHAR(500) = (SELECT Message FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] held tray LOT blocks ship (Status 0)',
    @Expected = N'0', @Actual = @SA1;
DECLARE @HeldName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @HeldTrayLot);
DECLARE @MsgNamesLot NVARCHAR(10) = CASE WHEN @MA1 LIKE N'%' + @HeldName + N'%' AND @MA1 LIKE N'%on hold%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] refusal names the held LOT',
    @Expected = N'1', @Actual = @MsgNamesLot;
DECLARE @StA NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] refused container stays Complete (2)',
    @Expected = N'2', @Actual = @StA;

INSERT INTO @HR EXEC Quality.Hold_Release @HoldEventId = @HoldA, @ReleaseRemarks = N'test release', @AppUserId = 2;
DELETE FROM @HR;
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @SlidA, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @SA2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] after release the SAME container ships (Status 1)',
    @Expected = N'1', @Actual = @SA2;

-- =====================================================================
-- Container B: completes clean, then a packed tray is held (recall case),
-- then a serial's producing LOT is held
-- =====================================================================
DECLARE @ConB BIGINT, @FirstTrayLotB BIGINT;
SET @t = 1;
WHILE @t <= 4
BEGIN
    DELETE FROM @AT;
    INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray
        @FinishedGoodItemId = @Fg, @PieceCount = 6, @CellLocationId = @Cell,
        @ClosureMethod = N'ByVision', @AppUserId = 1, @TerminalLocationId = @Term;
    SET @ConB = (SELECT ContainerId FROM @AT);
    IF @t = 1 SET @FirstTrayLotB = (SELECT FinishedGoodLotId FROM @AT);
    SET @t = @t + 1;
END
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @ConB, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @SlidB BIGINT = (SELECT ShippingLabelId FROM @CC); DELETE FROM @CC;

-- B1: hold a tray LOT that is already Closed in the completed container
INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @FirstTrayLotB, @HoldTypeCodeId = @HoldType, @Reason = N'test recall', @AppUserId = 2;
DECLARE @HoldB1 BIGINT = (SELECT NewId FROM @HP); DELETE FROM @HP;
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @SlidB, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @SB1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] tray held after completion blocks ship (Status 0)',
    @Expected = N'0', @Actual = @SB1;
INSERT INTO @HR EXEC Quality.Hold_Release @HoldEventId = @HoldB1, @ReleaseRemarks = N'test release', @AppUserId = 2;
DELETE FROM @HR;

-- B2: a serial in the container whose producing LOT is held
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Fg, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 1, @AppUserId = 1;
DECLARE @ProdLot BIGINT = (SELECT NewId FROM @CL);
DECLARE @M TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M EXEC Lots.SerializedPart_Mint @ItemId = @Fg, @ProducingLotId = @ProdLot, @AppUserId = 1;
DECLARE @Sp BIGINT = (SELECT NewId FROM @M);
DECLARE @SA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SA EXEC Lots.ContainerSerial_Add @ContainerId = @ConB, @SerializedPartId = @Sp, @HardwareInterlockBypassed = 0, @AppUserId = 1;
DECLARE @CsId BIGINT = (SELECT NewId FROM @SA);
DECLARE @SerialAdded NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SA);
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] serial placed in container B (fixture sanity)',
    @Expected = N'1', @Actual = @SerialAdded;

INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @ProdLot, @HoldTypeCodeId = @HoldType, @Reason = N'test serial hold', @AppUserId = 2;
DELETE FROM @HP;
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @SlidB, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @SB2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] held producing LOT of a packed serial blocks ship (Status 0)',
    @Expected = N'0', @Actual = @SB2;

-- B3: once that serial is out of the container, its LOT's hold no longer blocks.
-- Fixture shortcut: stamp RemovedAt directly (rework scrap is the real writer).
UPDATE Lots.ContainerSerial SET RemovedAt = SYSUTCDATETIME() WHERE Id = @CsId;
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @SlidB, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @SB3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH); DELETE FROM @SH;
EXEC test.Assert_IsEqual @TestName = N'[LotHoldShip] removed serial''s held LOT does not block (Status 1)',
    @Expected = N'1', @Actual = @SB3;

DELETE FROM Lots.AimShipperIdPool;
GO

-- ---- teardown (same as the top) ----
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @TdShip BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPOUT');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip));
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.Container c ON c.Id = cs.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.SerializedPart WHERE ProducingLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

EXEC test.EndTestFile;
