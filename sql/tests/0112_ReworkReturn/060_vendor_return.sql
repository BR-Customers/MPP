-- =============================================
-- File:        0112_ReworkReturn/060_vendor_return.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 6 -- return to vendor.
--                * Lots.VendorReturn_Mark takes the quantity off a Received /
--                  ReceivedOffsite LOT (PieceCount + InventoryAvailable together),
--                  records what was taken, writes no RejectEvent, audits it;
--                * refusals: Manufactured, over PieceCount, qty 0, Closed / Scrap /
--                  Open; a Hold LOT is allowed;
--                * InventoryAvailable below qty is floored at 0, InventoryTaken =
--                  the old InventoryAvailable;
--                * Good LOT marked to zero closes (LotStatusHistory), Hold stays Hold;
--                * Confirm stamps once; Cancel restores exactly, not after confirm,
--                  not on a Closed LOT, allowed on Hold-at-zero;
--                * ListOpen / ListByLot.
--              LOTs named TEST-VR-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/060_vendor_return.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-VR-%';
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

DECLARE @App       BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OriginOff BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'ReceivedOffsite');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @StGood    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @StHold    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @StClosed  BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @StScrap   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap');
DECLARE @StOpen    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @ItemId BIGINT, @Cell BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @Cell = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @m NVARCHAR(500);
DECLARE @L BIGINT;
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Vr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @Vs TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Rej0 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent);

SET @n = CASE WHEN @App IS NOT NULL AND @ItemId IS NOT NULL AND @Cell IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[VR] fixture: user, item, eligible location', @Expected = N'ok', @Actual = @n;

-- ---- LOTs ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 50, @AppUserId = @App, @LotName = N'TEST-VR-R1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @R1 BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginOff, @CurrentLocationId = @Cell, @PieceCount = 30, @AppUserId = @App, @LotName = N'TEST-VR-R2';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @R2 BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 30, @AppUserId = @App, @LotName = N'TEST-VR-M1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @M1 BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginMfg WHERE Id = @M1;

-- ---- mark 10 on Received ----
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @R1, @Quantity = 10, @Remarks = N'wrong alloy', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @L = NewId FROM @Vr; DELETE FROM @Vr;
DECLARE @V1 BIGINT = @L;
EXEC test.Assert_IsEqual @TestName = N'[VR] mark 10 on Received: status 1', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @R1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] mark 10 on Received: PieceCount 40', @Expected = N'40', @Actual = @n;
SET @n = CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @R1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] mark 10 on Received: InventoryAvailable 40', @Expected = N'40', @Actual = @n;
SET @n = CAST((SELECT PieceCountTaken FROM Lots.VendorReturn WHERE Id = @V1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] mark 10 on Received: PieceCountTaken 10', @Expected = N'10', @Actual = @n;
SET @n = CAST((SELECT InventoryTaken FROM Lots.VendorReturn WHERE Id = @V1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] mark 10 on Received: InventoryTaken 10', @Expected = N'10', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent) - @Rej0 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] no RejectEvent written', @Expected = N'0', @Actual = @n;
SET @n = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE LotId = @R1 AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'VendorReturnMarked') ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[VR] VendorReturnMarked audit row on LotEventLog', @HaystackStr = @n, @NeedleStr = N'Vendor return';
EXEC test.Assert_Contains @TestName = N'[VR] audit Description names the quantity', @HaystackStr = @n, @NeedleStr = N'Marked 10';

-- ---- ReceivedOffsite allowed ----
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @R2, @Quantity = 5, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] mark on ReceivedOffsite allowed', @Expected = N'1', @Actual = @n;

-- ---- Manufactured refused ----
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @M1, @Quantity = 5, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @m = Message FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] Manufactured refused: status 0', @Expected = N'0', @Actual = @n;
EXEC test.Assert_IsEqual @TestName = N'[VR] Manufactured refused: message',
    @Expected = N'LOT TEST-VR-M1 was made at MPP; only purchased or received material can be returned to a vendor.', @Actual = @m;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @M1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] Manufactured refused: LOT untouched', @Expected = N'30', @Actual = @n;

-- ---- over PieceCount / qty 0 ----
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @R1, @Quantity = 41, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] over PieceCount refused', @Expected = N'0', @Actual = @n;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @R1, @Quantity = 0, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] quantity 0 refused', @Expected = N'0', @Actual = @n;

-- ---- Closed / Scrap / Open refused; Hold allowed ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-VR-S1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @S1 BIGINT = @L;
UPDATE Lots.Lot SET LotStatusId = @StClosed WHERE Id = @S1;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S1, @Quantity = 5, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] Closed LOT refused', @Expected = N'0', @Actual = @n;
UPDATE Lots.Lot SET LotStatusId = @StScrap WHERE Id = @S1;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S1, @Quantity = 5, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] Scrap LOT refused', @Expected = N'0', @Actual = @n;
UPDATE Lots.Lot SET LotStatusId = @StOpen WHERE Id = @S1;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S1, @Quantity = 5, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] Open LOT refused', @Expected = N'0', @Actual = @n;
UPDATE Lots.Lot SET LotStatusId = @StHold WHERE Id = @S1;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S1, @Quantity = 5, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vr; DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[VR] Hold LOT allowed', @Expected = N'1', @Actual = @n;

-- ---- InventoryAvailable below qty: floored at 0 ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 50, @AppUserId = @App, @LotName = N'TEST-VR-I1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @I1 BIGINT = @L;
UPDATE Lots.Lot SET InventoryAvailable = 6 WHERE Id = @I1;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @I1, @Quantity = 10, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @L = NewId FROM @Vr; DELETE FROM @Vr;
DECLARE @VI BIGINT = @L;
EXEC test.Assert_IsEqual @TestName = N'[VR] InventoryAvailable below qty: allowed', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @I1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] InventoryAvailable below qty: floored at 0', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @I1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] InventoryAvailable below qty: PieceCount 40', @Expected = N'40', @Actual = @n;
SET @n = CAST((SELECT InventoryTaken FROM Lots.VendorReturn WHERE Id = @VI) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] InventoryAvailable below qty: InventoryTaken = old InventoryAvailable (6)', @Expected = N'6', @Actual = @n;
SET @n = CAST((SELECT PieceCountTaken FROM Lots.VendorReturn WHERE Id = @VI) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] InventoryAvailable below qty: PieceCountTaken 10', @Expected = N'10', @Actual = @n;
-- cancel restores exactly (40+10 / 0+6)
INSERT INTO @Vs EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VI, @CancelRemarks = N'keep it', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel (floored case): status 1', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @I1) AS NVARCHAR(10)) + N'/' + CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @I1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel restores exactly the taken amounts (50 / 6)', @Expected = N'50/6', @Actual = @n;

-- ---- Good LOT to zero closes; Hold LOT to zero stays Hold ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = @App, @LotName = N'TEST-VR-Z1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @Z1 BIGINT = @L;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @Z1, @Quantity = 12, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @L = NewId FROM @Vr; DELETE FROM @Vr;
DECLARE @VZ1 BIGINT = @L;
EXEC test.Assert_IsEqual @TestName = N'[VR] Good LOT marked to zero: status 1', @Expected = N'1', @Actual = @n;
SET @n = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Z1);
EXEC test.Assert_IsEqual @TestName = N'[VR] Good LOT marked to zero closes', @Expected = N'Closed', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotStatusHistory WHERE LotId = @Z1 AND NewStatusId = @StClosed AND OldStatusId = @StGood) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] Good LOT marked to zero: LotStatusHistory row', @Expected = N'1', @Actual = @n;
-- cancel on the now-Closed LOT refused
INSERT INTO @Vs EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VZ1, @CancelRemarks = N'oops', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel on a now-Closed LOT refused', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.VendorReturn WHERE Id = @VZ1 AND CancelledAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel on a now-Closed LOT: return still open', @Expected = N'1', @Actual = @n;

INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 8, @AppUserId = @App, @LotName = N'TEST-VR-Z2';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @Z2 BIGINT = @L;
UPDATE Lots.Lot SET LotStatusId = @StHold WHERE Id = @Z2;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @Z2, @Quantity = 8, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @L = NewId FROM @Vr; DELETE FROM @Vr;
DECLARE @VZ2 BIGINT = @L;
SET @n = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Z2);
EXEC test.Assert_IsEqual @TestName = N'[VR] Hold LOT marked to zero stays Hold', @Expected = N'Hold', @Actual = @n;
INSERT INTO @Vs EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VZ2, @CancelRemarks = N'back on the shelf', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] Hold-at-zero cancel allowed', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Z2) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] Hold-at-zero cancel restores 8', @Expected = N'8', @Actual = @n;

-- ---- ListOpen / Confirm ----
DECLARE @Open TABLE (VendorReturnId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(100),
                     VendorLotNumber NVARCHAR(100), Quantity INT, Remarks NVARCHAR(500),
                     MarkedByInitials NVARCHAR(10), MarkedAt DATETIME2(3), CurrentLocationName NVARCHAR(200));
INSERT INTO @Open EXEC Lots.VendorReturn_ListOpen;
SET @n = CAST((SELECT COUNT(*) FROM @Open WHERE VendorReturnId = @V1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] ListOpen lists the marked return', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM @Open WHERE VendorReturnId IN (@VI, @VZ2)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] ListOpen omits cancelled returns', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CONVERT(NVARCHAR(23), MarkedAt, 121) FROM @Open WHERE VendorReturnId = @V1);
SET @e = (SELECT CONVERT(NVARCHAR(23), CAST(MarkedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121) FROM Lots.VendorReturn WHERE Id = @V1);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListOpen MarkedAt is Eastern', @Expected = @e, @Actual = @n;
SET @n = (SELECT Remarks FROM @Open WHERE VendorReturnId = @V1);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListOpen carries the remarks', @Expected = N'wrong alloy', @Actual = @n;
DELETE FROM @Open;

INSERT INTO @Vs EXEC Lots.VendorReturn_Confirm @VendorReturnId = @V1, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm: status 1', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.VendorReturn WHERE Id = @V1 AND ConfirmedAt IS NOT NULL AND ConfirmedByUserId = @App) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm: stamped', @Expected = N'1', @Actual = @n;
INSERT INTO @Open EXEC Lots.VendorReturn_ListOpen;
SET @n = CAST((SELECT COUNT(*) FROM @Open WHERE VendorReturnId = @V1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm: gone from ListOpen', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @R1) AS NVARCHAR(10)) + N'/' + CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @R1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm: quantities unchanged', @Expected = N'40/40', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotEventLog WHERE LotId = @R1 AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'VendorReturnConfirmed')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm: audit row', @Expected = N'1', @Actual = @n;
INSERT INTO @Vs EXEC Lots.VendorReturn_Confirm @VendorReturnId = @V1, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm twice refused', @Expected = N'0', @Actual = @n;

-- ---- cancel after confirm refused; cancel twice refused ----
INSERT INTO @Vs EXEC Lots.VendorReturn_Cancel @VendorReturnId = @V1, @CancelRemarks = N'too late', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel after confirm refused', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @R1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel after confirm: quantity not restored', @Expected = N'40', @Actual = @n;
INSERT INTO @Vs EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VI, @CancelRemarks = N'again', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel twice refused', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @I1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] cancel twice: quantity restored only once', @Expected = N'50', @Actual = @n;
INSERT INTO @Vs EXEC Lots.VendorReturn_Confirm @VendorReturnId = @VI, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Vs; DELETE FROM @Vs;
EXEC test.Assert_IsEqual @TestName = N'[VR] confirm after cancel refused', @Expected = N'0', @Actual = @n;

-- ---- ListByLot: Confirmed / Cancelled / Open per row, CanCancel ----
-- R1: one confirmed (V1) + a fresh open mark
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @R1, @Quantity = 4, @AppUserId = @App;
SELECT @L = NewId FROM @Vr; DELETE FROM @Vr;
DECLARE @V1b BIGINT = @L;
DECLARE @ByLot TABLE (VendorReturnId BIGINT, Quantity INT, Remarks NVARCHAR(500), MarkedByInitials NVARCHAR(10),
                      MarkedAt DATETIME2(3), ConfirmedByInitials NVARCHAR(10), ConfirmedAt DATETIME2(3),
                      CancelledByInitials NVARCHAR(10), CancelledAt DATETIME2(3), CancelRemarks NVARCHAR(500),
                      StateCode NVARCHAR(20), CanCancel BIT, Seq INT IDENTITY(1,1));
INSERT INTO @ByLot (VendorReturnId, Quantity, Remarks, MarkedByInitials, MarkedAt, ConfirmedByInitials, ConfirmedAt,
                    CancelledByInitials, CancelledAt, CancelRemarks, StateCode, CanCancel)
EXEC Lots.VendorReturn_ListByLot @LotId = @R1;
SET @n = CAST((SELECT COUNT(*) FROM @ByLot) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: two rows for R1', @Expected = N'2', @Actual = @n;
SET @n = CAST((SELECT TOP 1 VendorReturnId FROM @ByLot ORDER BY Seq) AS NVARCHAR(20));
SET @e = CAST(@V1b AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: newest first', @Expected = @e, @Actual = @n;
SET @n = (SELECT StateCode + N'/' + CAST(CanCancel AS NVARCHAR(1)) FROM @ByLot WHERE VendorReturnId = @V1b);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: open row = Open, CanCancel 1', @Expected = N'Open/1', @Actual = @n;
SET @n = (SELECT StateCode + N'/' + CAST(CanCancel AS NVARCHAR(1)) FROM @ByLot WHERE VendorReturnId = @V1);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: confirmed row = Confirmed, CanCancel 0', @Expected = N'Confirmed/0', @Actual = @n;
SET @n = (SELECT ConfirmedByInitials FROM @ByLot WHERE VendorReturnId = @V1);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: ConfirmedByInitials', @Expected = N'SYS', @Actual = @n;
DELETE FROM @ByLot;
INSERT INTO @ByLot (VendorReturnId, Quantity, Remarks, MarkedByInitials, MarkedAt, ConfirmedByInitials, ConfirmedAt,
                    CancelledByInitials, CancelledAt, CancelRemarks, StateCode, CanCancel)
EXEC Lots.VendorReturn_ListByLot @LotId = @I1;
SET @n = (SELECT StateCode + N'/' + CAST(CanCancel AS NVARCHAR(1)) + N'/' + ISNULL(CancelRemarks, N'?') FROM @ByLot WHERE VendorReturnId = @VI);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: cancelled row = Cancelled, CanCancel 0, remarks', @Expected = N'Cancelled/0/keep it', @Actual = @n;
DELETE FROM @ByLot;
INSERT INTO @ByLot (VendorReturnId, Quantity, Remarks, MarkedByInitials, MarkedAt, ConfirmedByInitials, ConfirmedAt,
                    CancelledByInitials, CancelledAt, CancelRemarks, StateCode, CanCancel)
EXEC Lots.VendorReturn_ListByLot @LotId = @Z1;
SET @n = (SELECT StateCode + N'/' + CAST(CanCancel AS NVARCHAR(1)) FROM @ByLot WHERE VendorReturnId = @VZ1);
EXEC test.Assert_IsEqual @TestName = N'[VR] ListByLot: open return on a Closed LOT cannot be cancelled', @Expected = N'Open/0', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-VR-%';
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO
EXEC test.EndTestFile;
GO
