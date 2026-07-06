-- =============================================
-- File:         0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Lots.Lot_GetLineInventoryByPart (Spec 2 Task I1). On-hand inventory
--               at a cell, grouped by part then FIFO by arrival. Two parts seeded
--               at MA1-COMPBR-MIN, each with several LOTs:
--                 - open LOTs (Good, InventoryAvailable > 0) are returned;
--                 - a Closed LOT and a zero-inventory LOT are EXCLUDED;
--                 - rows are ordered PartNumber ASC, then arrival (latest
--                   LotMovement into the cell, falling back to CreatedAt) ASC,
--                   then LotId -- proven by inserting LOTs whose identity order is
--                   the REVERSE of their arrival order;
--                 - the ArrivedAt fallback to CreatedAt (no inbound movement)
--                   still sorts correctly.
--               Assertions are scoped to the seeded parts so any unrelated cell
--               inventory left by earlier files cannot perturb the counts.
--               Fixture cell: MA1-COMPBR-MIN.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql';
GO

-- ---- cleanup (FK-safe: movement -> event log -> LOTs) ----
DECLARE @PA0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-A');
DECLARE @PB0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-B');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId IN (@PA0, @PB0) OR l.LotName LIKE N'I1T-%';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId
    WHERE l.ItemId IN (@PA0, @PB0) OR l.LotName LIKE N'I1T-%';
DELETE FROM Lots.Lot WHERE ItemId IN (@PA0, @PB0) OR LotName LIKE N'I1T-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-I1-A')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-I1-A', N'I1 inventory part A', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-I1-B')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-I1-B', N'I1 inventory part B', 1, @Now, 1);
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-B');

-- LOTs for part A. Insert in REVERSE arrival order so identity order != FIFO order.
-- A3 inserted first (lowest Id) but arrives LAST; A1 inserted last but arrives FIRST.
--   A3: no inbound movement -> ArrivedAt falls back to CreatedAt (@Now + 20s) -> last
--   A2: inbound movement @Now + 10s -> middle
--   A1: inbound movement @Now (earliest) + a DECOY movement to another loc later -> first
--   A-CLOSED: Closed status (excluded); A-ZERO: InventoryAvailable 0 (excluded)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'I1T-A3', @A, 1, 1, 5,  5,  @Cell, 1, DATEADD(SECOND, 20, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'I1T-A2', @A, 1, 1, 20, 20, @Cell, 1, DATEADD(SECOND, -5, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'I1T-A1', @A, 1, 1, 30, 30, @Cell, 1, DATEADD(SECOND, -5, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'I1T-ACLOSED', @A, 1, 4, 15, 15, @Cell, 1, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'I1T-AZERO', @A, 1, 1, 12, 0,  @Cell, 1, @Now);
-- one LOT for part B (arrives @Now + 5s) -- proves part grouping (A before B)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'I1T-B1', @B, 1, 1, 40, 40, @Cell, 1, @Now);

DECLARE @A1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'I1T-A1');
DECLARE @A2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'I1T-A2');
DECLARE @B1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'I1T-B1');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-MIN');

-- inbound movements INTO the cell (set ArrivedAt); A3 gets none (fallback path).
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@A1, NULL, @Cell, 1, @Now);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@A2, NULL, @Cell, 1, DATEADD(SECOND, 10, @Now));
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@B1, NULL, @Cell, 1, DATEADD(SECOND, 5, @Now));
-- DECOY: a LATER movement for A1 to a DIFFERENT location -- proc must ignore it
-- (ToLocationId <> @Cell), so A1's ArrivedAt stays @Now and it still sorts first.
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@A1, @Cell, @Other, 1, DATEADD(SECOND, 60, @Now));
GO

-- =============================================
-- Test: on-hand grouped part -> FIFO
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

CREATE TABLE #inv (Seq INT IDENTITY(1,1), ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500),
                   LotId BIGINT, LotName NVARCHAR(50), InventoryAvailable INT, ArrivedAt DATETIME2(3));
INSERT INTO #inv (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt)
    EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell;

-- only the 4 open, non-zero LOTs of my two parts (Closed + zero-inv excluded)
DECLARE @MineCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #inv WHERE PartNumber IN (N'P-I1-A', N'P-I1-B'));
EXEC test.Assert_IsEqual @TestName = N'[LineInv] four open on-hand LOTs across the two parts', @Expected = N'4', @Actual = @MineCnt;

-- Closed LOT excluded
DECLARE @ClosedCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #inv WHERE LotName = N'I1T-ACLOSED');
EXEC test.Assert_IsEqual @TestName = N'[LineInv] Closed LOT excluded', @Expected = N'0', @Actual = @ClosedCnt;

-- zero-inventory LOT excluded
DECLARE @ZeroCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #inv WHERE LotName = N'I1T-AZERO');
EXEC test.Assert_IsEqual @TestName = N'[LineInv] zero-inventory LOT excluded', @Expected = N'0', @Actual = @ZeroCnt;

-- InventoryAvailable carried through correctly (A1 = 30)
DECLARE @A1Inv NVARCHAR(10) = (SELECT CAST(InventoryAvailable AS NVARCHAR(10)) FROM #inv WHERE LotName = N'I1T-A1');
EXEC test.Assert_IsEqual @TestName = N'[LineInv] InventoryAvailable correct (A1 = 30)', @Expected = N'30', @Actual = @A1Inv;

-- FIFO order WITHIN part A: A1 (earliest arrival) -> A2 -> A3 (CreatedAt fallback, latest)
DECLARE @SeqA1 INT = (SELECT Seq FROM #inv WHERE LotName = N'I1T-A1');
DECLARE @SeqA2 INT = (SELECT Seq FROM #inv WHERE LotName = N'I1T-A2');
DECLARE @SeqA3 INT = (SELECT Seq FROM #inv WHERE LotName = N'I1T-A3');
DECLARE @FifoOk BIT = CASE WHEN @SeqA1 < @SeqA2 AND @SeqA2 < @SeqA3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LineInv] FIFO within part A: A1 < A2 < A3 (arrival, not identity)', @Condition = @FifoOk;

-- part grouping: every part-A row precedes the part-B row
DECLARE @MaxSeqA INT = (SELECT MAX(Seq) FROM #inv WHERE PartNumber = N'P-I1-A');
DECLARE @SeqB1 INT = (SELECT Seq FROM #inv WHERE LotName = N'I1T-B1');
DECLARE @GroupOk BIT = CASE WHEN @MaxSeqA < @SeqB1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LineInv] parts grouped: all P-I1-A rows precede P-I1-B', @Condition = @GroupOk;

DROP TABLE #inv;
GO

-- ---- cleanup ----
DECLARE @PA0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-A');
DECLARE @PB0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-B');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId IN (@PA0, @PB0) OR l.LotName LIKE N'I1T-%';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId
    WHERE l.ItemId IN (@PA0, @PB0) OR l.LotName LIKE N'I1T-%';
DELETE FROM Lots.Lot WHERE ItemId IN (@PA0, @PB0) OR LotName LIKE N'I1T-%';
GO

EXEC test.EndTestFile;
GO
