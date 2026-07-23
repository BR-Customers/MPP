-- =============================================
-- File:         0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql
-- Author:       Blue Ridge Automation
-- Rewritten:    2026-07-23 - Trim-Storage model (v2). Rejection guards:
--                 - LOT not in Trim Storage (e.g. still off in a non-storage cell) -> reject
--                 - terminal not part of the line -> reject
--                 - Closed LOT -> reject
--               Fixture: routed casting 5G0-c eligible at the LINE MA1-5GOF; Trim Storage
--               TRIM1-STORE; a non-storage/off-line cell DC1-M05.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql';
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Line, 0, SYSUTCDATETIME());
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-GUARD-%';
GO

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Term  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @OffLoc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');   -- non-storage / off-line
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- ---- Guard 1: LOT not in Trim Storage ----
DECLARE @Lot1 BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-A';
SELECT @Lot1 = NewId FROM #C; DELETE FROM #C;
UPDATE Lots.Lot SET CurrentLocationId = @OffLoc WHERE Id = @Lot1;   -- not in Trim Storage
DECLARE @S1 BIT, @M1 NVARCHAR(500);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot1, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S1 = Status, @M1 = Message FROM #R1; DROP TABLE #R1;
DECLARE @S1c BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] LOT not in Trim Storage is rejected', @Condition = @S1c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection cites not in Trim Storage', @HaystackStr = @M1, @NeedleStr = N'not in Trim Storage';

-- ---- Guard 2: terminal not part of the line (LOT staged in Trim Storage, eligible) ----
DECLARE @Lot2 BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-B';
SELECT @Lot2 = NewId FROM #C; DELETE FROM #C;
UPDATE Lots.Lot SET CurrentLocationId = @Store WHERE Id = @Lot2;   -- in Trim Storage
DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot2, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @OffLoc;
SELECT @S2 = Status, @M2 = Message FROM #R2; DROP TABLE #R2;
DECLARE @S2c BIT = CASE WHEN @S2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] off-line terminal is rejected', @Condition = @S2c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection cites terminal not on the line', @HaystackStr = @M2, @NeedleStr = N'Terminal is not part of this line';

-- ---- Guard 3: Closed LOT ----
DECLARE @Lot3 BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-C';
SELECT @Lot3 = NewId FROM #C; DROP TABLE #C;
UPDATE Lots.Lot SET CurrentLocationId = @Store, LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') WHERE Id = @Lot3;
DECLARE @S3 BIT;
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot3, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S3 = Status FROM #R3; DROP TABLE #R3;
DECLARE @S3c BIT = CASE WHEN @S3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] Closed LOT is rejected', @Condition = @S3c;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-GUARD-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-GUARD-%';
GO

EXEC test.EndTestFile;
GO
