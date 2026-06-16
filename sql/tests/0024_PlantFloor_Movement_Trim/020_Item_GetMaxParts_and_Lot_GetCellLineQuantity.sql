-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/020_Item_GetMaxParts_and_Lot_GetCellLineQuantity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Parts.Item_GetMaxParts + Lots.Lot_GetCellLineQuantity
--               (Arc 2 Phase 4 sec 4.1).
--                 - Item_GetMaxParts returns the set value and NULL when unset
--                 - Lot_GetCellLineQuantity sums PieceCount across OPEN LOTs of one
--                   Item at one location; Closed LOTs excluded
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

-- ---- cleanup ----
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
