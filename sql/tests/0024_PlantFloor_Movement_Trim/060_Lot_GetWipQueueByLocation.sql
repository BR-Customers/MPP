-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Lots.Lot_GetWipQueueByLocation (Arc 2 Phase 4 sec 4.1).
--                 - arrival order (earliest LotMovement.MovedAt first)
--                 - Closed LOTs excluded
--                 - empty location -> 0 rows
--               Fixture item = 1 (5G0) at DC1-M05; Received origin. MovedAt is set
--               to deterministic distinct timestamps to assert ordering.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql';
GO

-- ---- fixture cleanup ----
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

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

-- Deterministic arrival order: L1 earliest, L2 later.
UPDATE Lots.LotMovement SET MovedAt = '2026-01-01T00:00:00' WHERE LotId = @L1;
UPDATE Lots.LotMovement SET MovedAt = '2026-02-01T00:00:00' WHERE LotId = @L2;

-- Close L3 (fixture flip) -> excluded.
DECLARE @ClosedId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
UPDATE Lots.Lot SET LotStatusId = @ClosedId WHERE Id = @L3;

CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), HasRenameBom BIT);
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @LocA;

DECLARE @First BIGINT = (SELECT TOP 1 Id FROM #Q ORDER BY LastMovementAt ASC, Id ASC);
DECLARE @FirstStr NVARCHAR(20) = CAST(@First AS NVARCHAR(20));
DECLARE @L1Str NVARCHAR(20) = CAST(@L1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] earliest-arrival LOT first', @Expected = @L1Str, @Actual = @FirstStr;

DECLARE @L3InQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @L3);
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] Closed LOT excluded', @Expected = N'0', @Actual = @L3InQ;

DECLARE @OpenCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id IN (@L1, @L2));
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] both open LOTs present', @Expected = N'2', @Actual = @OpenCnt;
DROP TABLE #Q;
GO

-- =============================================
-- Empty location -> 0 rows
-- =============================================
DECLARE @BadLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Lots.Lot x WHERE x.CurrentLocationId = l.Id)
    ORDER BY l.Id);
CREATE TABLE #Q2 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), HasRenameBom BIT);
INSERT INTO #Q2 EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @BadLoc;
DECLARE @Empty NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q2);
DROP TABLE #Q2;
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] empty location returns 0 rows', @Expected = N'0', @Actual = @Empty;
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
