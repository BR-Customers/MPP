-- =============================================
-- File:         0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Rejection guards for Workorder.MachiningIn_RecordPick:
--                 - LOT not checked into the line -> reject
--                 - terminal not part of the line -> reject
--                 - Closed LOT -> reject
--               Fixture: P5-CAST-TEST eligible at the LINE MA1-COMPBR. A non-line
--               location (DC1-M05) is used for the off-line cases.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql';
GO

-- ---- fixture (idempotent) ----
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P5-CAST-TEST', N'Phase5 test cast/trim part', 48, NULL, 1, @Now, 1);
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @SrcItem AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@SrcItem, @Line, 0, @Now);
GO

-- ---- LOT cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
GO

DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Term   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @OffLoc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');   -- not under MA1-COMPBR
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

-- ---- Guard 1: LOT not checked into the line ----
DECLARE @Lot1 BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-A';
SELECT @Lot1 = NewId FROM #C; DELETE FROM #C;
UPDATE Lots.Lot SET CurrentLocationId = @OffLoc WHERE Id = @Lot1;   -- move it off the line

DECLARE @S1 BIT, @M1 NVARCHAR(500);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot1, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S1 = Status, @M1 = Message FROM #R1; DROP TABLE #R1;
DECLARE @S1c BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] LOT not at the line is rejected', @Condition = @S1c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection cites not on the line', @HaystackStr = @M1, @NeedleStr = N'not checked into this line';

-- ---- Guard 2: terminal not part of the line ----
DECLARE @Lot2 BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-B';
SELECT @Lot2 = NewId FROM #C; DELETE FROM #C;

DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot2, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @OffLoc;
SELECT @S2 = Status, @M2 = Message FROM #R2; DROP TABLE #R2;
DECLARE @S2c BIT = CASE WHEN @S2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] off-line terminal is rejected', @Condition = @S2c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection cites terminal not on the line', @HaystackStr = @M2, @NeedleStr = N'Terminal is not part of this line';

-- ---- Guard 3: Closed LOT ----
DECLARE @Lot3 BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-C';
SELECT @Lot3 = NewId FROM #C; DROP TABLE #C;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') WHERE Id = @Lot3;

DECLARE @S3 BIT;
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot3, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S3 = Status FROM #R3; DROP TABLE #R3;
DECLARE @S3c BIT = CASE WHEN @S3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] Closed LOT is rejected', @Condition = @S3c;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
GO

EXEC test.EndTestFile;
GO
