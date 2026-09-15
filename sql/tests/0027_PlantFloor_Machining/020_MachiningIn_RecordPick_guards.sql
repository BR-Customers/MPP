-- =============================================
-- File:         0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql
-- Author:       Blue Ridge Automation
-- Rewritten:    2026-09-15 - route-driven claim. Rejection guards:
--                 - LOT whose next pending route step is not MachiningIn -> reject,
--                   EVEN WHEN IT IS SITTING IN TRIM STORAGE (location is no longer a gate)
--                 - terminal not part of the line -> reject (fixture pre-advanced to
--                   MachiningIn-pending so this guard reaches the terminal check)
--                 - Closed LOT -> reject (status guard precedes the route gate)
--               Fixture: routed casting 5G0-c eligible at the LINE MA1-5GOF; Trim Storage
--               TRIM1-STORE; a non-storage/off-line cell DC1-M05 (the off-line terminal).
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
-- Deliberately IN Trim Storage: under the route-driven model (2026-09-15) sitting in
-- the right place is not enough. This LOT has no ProductionEvents, so its next pending
-- route step is TrimIn -- and that, not its location, is what rejects the claim.
UPDATE Lots.Lot SET CurrentLocationId = @Store WHERE Id = @Lot1;
DECLARE @S1 BIT, @M1 NVARCHAR(500);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Workorder.MachiningIn_RecordPick @LotId = @Lot1, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S1 = Status, @M1 = Message FROM #R1; DROP TABLE #R1;
DECLARE @S1c BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] LOT whose next route step is not MachiningIn is rejected', @Condition = @S1c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection names the actual next operation', @HaystackStr = @M1, @NeedleStr = N'next operation is TrimIn';

-- ---- Guard 2: terminal not part of the line (LOT staged in Trim Storage, eligible) ----
DECLARE @Lot2 BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-GUARD-B';
SELECT @Lot2 = NewId FROM #C; DELETE FROM #C;
UPDATE Lots.Lot SET CurrentLocationId = @Store WHERE Id = @Lot2;   -- in Trim Storage
-- Pre-advance past DieCast/TrimIn/TrimOut so the next pending step really is
-- MachiningIn. Without this the route gate (step 3) rejects first and this guard
-- would pass for the wrong reason, never reaching the terminal check it exists to test.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot2, rs.OperationTemplateId, SYSUTCDATETIME(), 20, 1
FROM Parts.RouteTemplate rt
JOIN Parts.RouteStep rs          ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot  ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');
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
