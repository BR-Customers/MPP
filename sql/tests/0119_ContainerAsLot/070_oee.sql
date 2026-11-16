-- =============================================
-- File:         0119_ContainerAsLot/070_oee.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Container-as-LOT spec 7.5, D5, D11: M&A good per shift is read from
--               the TRAYS (ShiftId + fixed MintedPieceCount at the station), so a
--               container that spans a shift change credits each shift with its own
--               trays; a MIXED container counts its old tray LOT once (via the LOT)
--               and its new trays once each; repack scrap after the shift changes
--               neither good nor the fingerprint; a rework-move tray (no ShiftId)
--               never counts; BackfillMintStamp leaves a container LOT unstamped;
--               the FG KPI counts a container LOT once with its trays' pieces.
--               Station: MA1-COMPBR-AOUT (area family 'ma').
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/070_oee.sql';
GO

DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'P118-OEE', N'0119 OEE finished good', 1, @Now, 1);
DECLARE @Item BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 4, 4, 0, N'ByCount', @Now);
DECLARE @Cfg BIGINT = SCOPE_IDENTITY();

-- two consecutive closed shifts in 2020 (clear of every other fixture)
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'T118-070-SCHED', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
DECLARE @Sched BIGINT = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2020-03-02T06:00:00', '2020-03-02T14:00:00', N'T118-070-A'),
       (@Sched, '2020-03-02T14:00:00', '2020-03-02T22:00:00', N'T118-070-B');
DECLARE @SA BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'T118-070-A');
DECLARE @SB BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'T118-070-B');

-- NEW container: trays 1-2 in shift A, tray 3 in shift B
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
VALUES (N'T118-070-N', @Item, 1, 1, 12, @Term, 1, @Term, '2020-03-02T13:00:00');
DECLARE @LN BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId, OpenedAt)
VALUES (@Item, @Cfg, @Term, 1, @LN, '2020-03-02T13:00:00');
DECLARE @CN BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ShiftId, ClosedAtTerminalId, MintedPieceCount)
VALUES (@CN, 1, 4, '2020-03-02T13:00:00', @SA, @Term, 4),
       (@CN, 2, 4, '2020-03-02T13:30:00', @SA, @Term, 4),
       (@CN, 3, 4, '2020-03-02T14:30:00', @SB, @Term, 4),
       -- a rework-move tray: no ShiftId / MintedPieceCount
       (@CN, 4, 3, '2020-03-02T15:00:00', NULL, NULL, NULL);

-- MIXED container: an old tray LOT (stamped on the LOT, shift A) + a new tray (shift A)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CreatedAt, ShiftId, MintedPieceCount)
VALUES (N'T118-070-MOLD', @Item, 1, 1, 4, @Term, 1, @Term, '2020-03-02T07:00:00', @SA, 4);
DECLARE @LMOld BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
VALUES (N'T118-070-MNEW', @Item, 1, 1, 4, @Term, 1, @Term, '2020-03-02T08:00:00');
DECLARE @LMNew BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId, OpenedAt)
VALUES (@Item, @Cfg, @Term, 1, @LMNew, '2020-03-02T07:00:00');
DECLARE @CM BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId, ShiftId, ClosedAtTerminalId, MintedPieceCount)
VALUES (@CM, 1, 4, '2020-03-02T07:00:00', @LMOld, NULL, NULL, NULL),
       (@CM, 2, 4, '2020-03-02T08:00:00', NULL, @SA, @Term, 4);
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OEE');
DECLARE @SA BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'T118-070-A');
DECLARE @SB BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'T118-070-B');
DECLARE @LN BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-070-N');
DECLARE @CN BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LN);
DECLARE @c BIT;

-- shift A: new trays 1-2 (8) + mixed old tray LOT (4) + mixed new tray (4) = 16; shift B: 4
SET @c = CASE WHEN (SELECT SUM(Good) FROM Oee.ufn_ShiftGood(@SA) WHERE ItemId = @Item) = 16 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D5] shift A good = its trays (8) + mixed old tray LOT (4) + mixed new tray (4) = 16', @Condition = @c;
SET @c = CASE WHEN (SELECT SUM(Good) FROM Oee.ufn_ShiftGood(@SB) WHERE ItemId = @Item) = 4 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D5] shift B good = its one tray (4); the rework-move tray never counts', @Condition = @c;

-- D11: repack scrap after the shift changes neither good nor the fingerprint
DECLARE @FpBefore VARBINARY(32) = (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@SA));
UPDATE Lots.ContainerTray SET PartsClosedCount = PartsClosedCount - 2 WHERE ContainerId = @CN AND TrayPosition = 1;
UPDATE Lots.Lot SET PieceCount = PieceCount - 2 WHERE Id = @LN;
SET @c = CASE WHEN (SELECT SUM(Good) FROM Oee.ufn_ShiftGood(@SA) WHERE ItemId = @Item) = 16
               AND (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@SA)) = @FpBefore THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D11] repack scrap after the shift leaves good and the fingerprint unchanged', @Condition = @c;

-- the fingerprint does see a new tray stamped into the shift
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ShiftId, ClosedAtTerminalId, MintedPieceCount)
VALUES (@CN, 5, 4, '2020-03-02T13:45:00', @SA, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT'), 4);
SET @c = CASE WHEN (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@SA)) <> @FpBefore THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Fingerprint] a new tray in the shift changes the fingerprint', @Condition = @c;
DELETE FROM Lots.ContainerTray WHERE ContainerId = @CN AND TrayPosition = 5;

-- BackfillMintStamp leaves the container LOT unstamped
DECLARE @B TABLE (Info NVARCHAR(MAX));
BEGIN TRY
    EXEC Lots.Lot_BackfillMintStamp @Commit = 1, @AppUserId = 1;
END TRY
BEGIN CATCH
END CATCH;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @LN AND ShiftId IS NULL AND MintedPieceCount IS NULL) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Backfill] the container LOT stays unstamped', @Condition = @c;

-- FG KPI over shift B's window: one unit (the container LOT), pieces = its tray in the window
DECLARE @K TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotCount INT, PartCount INT);
INSERT INTO @K EXEC Workorder.FinishedGoods_GetProducedSummary @ShiftStartUtc = '2020-03-02T14:00:00', @ShiftEndUtc = '2020-03-02T22:00:00';
SET @c = CASE WHEN (SELECT LotCount FROM @K WHERE ItemId = @Item) = 1 AND (SELECT PartCount FROM @K WHERE ItemId = @Item) = 4 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[KPI] window 14:00-22:00: one container LOT, 4 pcs (tray 3; the moved-in tray is not production -- review M4)', @Condition = @c;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
