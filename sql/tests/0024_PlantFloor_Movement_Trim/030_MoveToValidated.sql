-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/030_MoveToValidated.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Lots.Lot_MoveToValidated (Arc 2 Phase 4 sec 4.2).
--                 - eligible move succeeds + LotMovement row + CurrentLocationId
--                   updated + LotMoved audit in LotEventLog
--                 - ineligible destination rejects (FDS-02-012)
--                 - blocked (Hold) LOT rejects (B2)
--                 - MaxParts overflow rejects (OI-12)
--                 - MaxParts NULL move is uncapped
--               Fixture item = 1 (5G0), eligible at DC1-M05/M06/M07; Received origin.
--               Item 1 MaxParts captured in #Orig (persists across GO in-session)
--               and restored at cleanup.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/030_MoveToValidated.sql';
GO

-- ---- fixture: clean + capture/neutralize Item 1 MaxParts ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
CREATE TABLE #Orig (MaxParts INT);
INSERT INTO #Orig SELECT MaxParts FROM Parts.Item WHERE Id = 1;
UPDATE Parts.Item SET MaxParts = NULL WHERE Id = 1;   -- uncapped for the eligibility tests
GO

-- =============================================
-- Test 1: eligible move succeeds (MaxParts NULL)
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @LocB, @AppUserId = 1;
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MoveOK] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @Cur NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @L);
DECLARE @LocBStr NVARCHAR(20) = CAST(@LocB AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MoveOK] CurrentLocationId = destination', @Expected = @LocBStr, @Actual = @Cur;

DECLARE @MovCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement WHERE LotId = @L AND ToLocationId = @LocB);
EXEC test.Assert_IsEqual @TestName = N'[MoveOK] LotMovement row to destination', @Expected = N'1', @Actual = @MovCnt;

DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog le
    INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
    WHERE et.Code = N'LotMoved' AND le.EntityId = @L);
EXEC test.Assert_IsEqual @TestName = N'[MoveOK] LotMoved audit in LotEventLog', @Expected = N'1', @Actual = @AudCnt;
GO

-- =============================================
-- Test 2: ineligible destination rejects
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @BadLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL AND l.Id NOT IN (SELECT LocationId FROM Parts.v_EffectiveItemLocation WHERE ItemId = 1)
    ORDER BY l.Id);

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @BadLoc, @AppUserId = 1;
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MoveIneligible] rejected (Status 0)', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: blocked (Hold) LOT rejects
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @L;

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @LocB, @AppUserId = 1;
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MoveBlocked] Hold LOT rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: MaxParts overflow rejects; then NULL uncaps
-- =============================================
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';

DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocC BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M07');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

UPDATE Parts.Item SET MaxParts = 30 WHERE Id = 1;

-- pre-place an open 20-piece LOT at the destination (M07)
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocC, @PieceCount = 20, @AppUserId = 1;
DELETE FROM #C;
-- the LOT to move, 20 pieces at M05
DECLARE @Q BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @Q = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @Q, @ToLocationId = @LocC, @AppUserId = 1;   -- 20 existing + 20 > 30
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MaxParts] overflow rejected', @Expected = N'0', @Actual = @SStr;

-- uncap and retry
UPDATE Parts.Item SET MaxParts = NULL WHERE Id = 1;
DECLARE @S2 BIT;
CREATE TABLE #M2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #M2 EXEC Lots.Lot_MoveToValidated @LotId = @Q, @ToLocationId = @LocC, @AppUserId = 1;
SELECT @S2 = Status FROM #M2; DROP TABLE #M2;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MaxParts] NULL uncaps the move', @Expected = N'1', @Actual = @S2Str;
GO

-- ---- cleanup: restore Item 1 MaxParts + drop lots ----
UPDATE Parts.Item SET MaxParts = (SELECT MaxParts FROM #Orig) WHERE Id = 1;
DROP TABLE #Orig;
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
