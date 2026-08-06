-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql
-- Description:  Lots.Lot_CloseInline (FAT #21) silent close helper. A Good LOT closes
--               to Closed (4) with a LotStatusHistory row + LotStatusChanged audit; a
--               Hold LOT is left untouched (Good-only guard).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql';
GO

DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD');
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE ItemTypeId = 3 ORDER BY Id);

-- A Good LOT and a Hold LOT (status 2) to prove the Good-only guard.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'FGC-085-GOOD', @Item, 1, 1, 10, @Cell, 0, 10, 1);
DECLARE @GoodLot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'FGC-085-HELD', @Item, 1, 2, 10, @Cell, 0, 10, 1);
DECLARE @HeldLot BIGINT = SCOPE_IDENTITY();

-- Act: close both via the helper (silent proc, called directly -- no INSERT-EXEC).
EXEC Lots.Lot_CloseInline @LotId = @GoodLot, @Reason = N'unit close', @AppUserId = 1, @TerminalLocationId = @Cell;
EXEC Lots.Lot_CloseInline @LotId = @HeldLot, @Reason = N'unit close', @AppUserId = 1, @TerminalLocationId = @Cell;

-- Assert: Good LOT is now Closed (4); Held LOT is untouched (still 2).
DECLARE @GoodStatus NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @GoodLot);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] Good LOT -> Closed (4)', @Expected = N'4', @Actual = @GoodStatus;
DECLARE @HeldStatus NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @HeldLot);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] Held LOT untouched (2)', @Expected = N'2', @Actual = @HeldStatus;

-- Assert: exactly one Good->Closed history row for the Good LOT.
DECLARE @Hist NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @GoodLot AND OldStatusId = 1 AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] one Good->Closed history row', @Expected = N'1', @Actual = @Hist;

-- Assert: a LotStatusChanged audit entry exists for the Good LOT.
-- B7 routing (Audit.Audit_LogOperation): entity 'Lot' + non-NULL EntityId writes
-- to the 20-yr Lots.LotEventLog, not the 7-yr Audit.OperationLog.
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'LotStatusChanged' AND el.LotId = @GoodLot);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] LotStatusChanged audit present', @Expected = N'1', @Actual = @Aud;
GO

DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD');
GO

EXEC test.EndTestFile;
GO
