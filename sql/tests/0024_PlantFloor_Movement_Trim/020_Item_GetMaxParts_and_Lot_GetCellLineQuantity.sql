-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/020_Item_GetMaxParts_and_Lot_GetCellLineQuantity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Parts.Item_GetMaxParts + Lots.Lot_GetCellLineQuantity
--               (Arc 2 Phase 4 sec 4.1).
--                 - Item_GetMaxParts returns the set value and NULL when unset
--                 - Lot_GetCellLineQuantity sums PieceCount across OPEN LOTs of one
--                   Item at one location; Closed LOTs excluded
--                 - (2026-11-16) Hold / Scrap / Open still count; other item and
--                   other location excluded; no match -> one row, 0
--               Fixture item = 1 (5G0), eligible at DC1-M05; Received origin so no
--               Tool/Cavity required. MaxParts is mutated then restored.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/020_Item_GetMaxParts_and_Lot_GetCellLineQuantity.sql';
GO

-- ---- fixture cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

-- =============================================
-- Test 1: Item_GetMaxParts (set value, then NULL) -- restored in-batch
-- =============================================
DECLARE @Orig INT = (SELECT MaxParts FROM Parts.Item WHERE Id = 1);

UPDATE Parts.Item SET MaxParts = 42 WHERE Id = 1;
CREATE TABLE #M1 (MaxParts INT);
INSERT INTO #M1 EXEC Parts.Item_GetMaxParts @ItemId = 1;
DECLARE @Got NVARCHAR(10) = (SELECT CAST(MaxParts AS NVARCHAR(10)) FROM #M1);
DROP TABLE #M1;
EXEC test.Assert_IsEqual @TestName = N'[MaxParts] reads set value 42', @Expected = N'42', @Actual = @Got;

UPDATE Parts.Item SET MaxParts = NULL WHERE Id = 1;
CREATE TABLE #M2 (MaxParts INT);
INSERT INTO #M2 EXEC Parts.Item_GetMaxParts @ItemId = 1;
DECLARE @GotNull NVARCHAR(10) = (SELECT CASE WHEN MaxParts IS NULL THEN N'1' ELSE N'0' END FROM #M2);
DROP TABLE #M2;
EXEC test.Assert_IsEqual @TestName = N'[MaxParts] reads NULL when unset', @Expected = N'1', @Actual = @GotNull;

UPDATE Parts.Item SET MaxParts = @Orig WHERE Id = 1;   -- restore
GO

-- =============================================
-- Test 2: Lot_GetCellLineQuantity sums OPEN LOTs, excludes Closed
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L1 BIGINT, @L2 BIGINT, @L3 BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 10, @AppUserId = 1;
SELECT @L1 = NewId FROM #C; DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 15, @AppUserId = 1;
SELECT @L2 = NewId FROM #C; DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 5, @AppUserId = 1;
SELECT @L3 = NewId FROM #C; DROP TABLE #C;

-- Close LOT 3 directly (fixture flip) so it is excluded from the open sum.
DECLARE @ClosedId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
UPDATE Lots.Lot SET LotStatusId = @ClosedId WHERE Id = @L3;

CREATE TABLE #Q (ExistingPieceCount INT);
INSERT INTO #Q EXEC Lots.Lot_GetCellLineQuantity @LocationId = @LocA, @ItemId = 1;
DECLARE @Sum NVARCHAR(10) = (SELECT CAST(ExistingPieceCount AS NVARCHAR(10)) FROM #Q);
DROP TABLE #Q;
EXEC test.Assert_IsEqual @TestName = N'[CellQty] open sum 10+15, Closed excluded', @Expected = N'25', @Actual = @Sum;
GO

-- =============================================
-- Test 3 (2026-11-16, SP review, v1.1 pin): only Closed is excluded -- Hold,
-- Scrap and die-cast Open LOTs still count; another item at the same location
-- and the same item at another location do not; nothing matching -> one row, 0.
-- Builds on Test 2's LOTs at DC1-M05 (10 + 15 open, 5 Closed).
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT TOP (1) Id FROM Location.Location WHERE Id <> @LocA ORDER BY Id);
DECLARE @OtherItem BIGINT = (SELECT TOP (1) Id FROM Parts.Item WHERE Id <> 1 ORDER BY Id);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L4 BIGINT, @L5 BIGINT, @L6 BIGINT, @L7 BIGINT, @L8 BIGINT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 7, @AppUserId = 1;
SELECT @L4 = NewId FROM #C3; DELETE FROM #C3;
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 11, @AppUserId = 1;
SELECT @L5 = NewId FROM #C3; DELETE FROM #C3;
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 13, @AppUserId = 1;
SELECT @L6 = NewId FROM #C3; DELETE FROM #C3;
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 17, @AppUserId = 1;
SELECT @L7 = NewId FROM #C3; DELETE FROM #C3;
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 19, @AppUserId = 1;
SELECT @L8 = NewId FROM #C3; DROP TABLE #C3;

-- Fixture flips (direct, as Test 2 does): statuses, then move two out of scope.
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold')  WHERE Id = @L4;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap') WHERE Id = @L5;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open')  WHERE Id = @L6;
UPDATE Lots.Lot SET ItemId = @OtherItem   WHERE Id = @L7;
UPDATE Lots.Lot SET CurrentLocationId = @LocB WHERE Id = @L8;

CREATE TABLE #Q3 (ExistingPieceCount INT);
INSERT INTO #Q3 EXEC Lots.Lot_GetCellLineQuantity @LocationId = @LocA, @ItemId = 1;
DECLARE @Sum3 NVARCHAR(10) = (SELECT CAST(ExistingPieceCount AS NVARCHAR(10)) FROM #Q3);
DELETE FROM #Q3;
EXEC test.Assert_IsEqual @TestName = N'[CellQty] Hold/Scrap/Open count; other item + other location excluded (10+15+7+11+13)', @Expected = N'56', @Actual = @Sum3;

INSERT INTO #Q3 EXEC Lots.Lot_GetCellLineQuantity @LocationId = @LocA, @ItemId = -1;
DECLARE @Rows3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q3);
DECLARE @Zero3 NVARCHAR(10) = (SELECT CAST(MAX(ExistingPieceCount) AS NVARCHAR(10)) FROM #Q3);
DROP TABLE #Q3;
EXEC test.Assert_IsEqual @TestName = N'[CellQty] no matching LOTs -> exactly one row', @Expected = N'1', @Actual = @Rows3;
EXEC test.Assert_IsEqual @TestName = N'[CellQty] no matching LOTs -> 0, not NULL', @Expected = N'0', @Actual = @Zero3;
GO

-- ---- cleanup ----
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
