-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Rejection tests for Workorder.TrimOut_Record (Arc 2 Phase 4 sec 4.3).
--                 - missing destination rejects
--                 - non-eligible destination rejects (FDS-02-012)
--                 - blocked (Hold) LOT rejects (B2)
--                 - counter regression (< prior cumulative) rejects (D1)
--               Fixture item = 1 (5G0), origin Received.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql';
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
-- Test 1: missing destination rejects
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT;
CREATE TABLE #T1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T1 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = NULL,
    @SourceLocationId = @LocA, @AppUserId = 1;
SELECT @S = Status FROM #T1; DROP TABLE #T1;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] missing destination rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 2: non-eligible destination rejects
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @BadLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL AND l.Id NOT IN (SELECT LocationId FROM Parts.v_EffectiveItemLocation WHERE ItemId = 1)
    ORDER BY l.Id);

DECLARE @S BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = @BadLoc,
    @SourceLocationId = @LocA, @AppUserId = 1;
SELECT @S = Status FROM #T2; DROP TABLE #T2;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] non-eligible destination rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: blocked (Hold) LOT rejects
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @L;

DECLARE @S BIT;
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T3 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = @LocB,
    @SourceLocationId = @LocA, @AppUserId = 1;
SELECT @S = Status FROM #T3; DROP TABLE #T3;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] blocked (Hold) LOT rejected', @Expected = N'0', @Actual = @SStr;

DECLARE @GoodId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
UPDATE Lots.Lot SET LotStatusId = @GoodId WHERE Id = @L;
GO

-- =============================================
-- Test 4: counter regression (< prior cumulative) rejects (D1)
-- =============================================
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';

DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @DcOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

-- establish a prior cumulative ShotCount of 10 on this LOT
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId = @L, @OperationTemplateId = @DcOt, @ShotCount = 10, @AppUserId = 1;
DROP TABLE #P;

DECLARE @S BIT;
CREATE TABLE #T4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T4 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 3, @DestinationCellLocationId = @LocB,
    @SourceLocationId = @LocA, @AppUserId = 1;  -- 3 < prior 10
SELECT @S = Status FROM #T4; DROP TABLE #T4;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] counter regression rejected (D1)', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 5: double checkout rejects (source-location guard, 2026-07-06)
--   First OUT succeeds (control); the LOT now sits at the destination, so a
--   second OUT with the same Trim source location must reject.
-- =============================================
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';

DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');

DECLARE @L BIGINT;
CREATE TABLE #C5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C5; DROP TABLE #C5;

DECLARE @S1 BIT, @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #T5a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5a EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = @LocB,
    @SourceLocationId = @LocA, @AppUserId = 1;
SELECT @S1 = Status FROM #T5a; DROP TABLE #T5a;
DECLARE @S1Str NVARCHAR(10) = CAST(@S1 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] first checkout succeeds (control)', @Expected = N'1', @Actual = @S1Str;

CREATE TABLE #T5b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5b EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = @LocB,
    @SourceLocationId = @LocA, @AppUserId = 1;
SELECT @S2 = Status, @M2 = Message FROM #T5b; DROP TABLE #T5b;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] double checkout rejected', @Expected = N'0', @Actual = @S2Str;

DECLARE @ReasonOk NVARCHAR(10) = CASE WHEN @M2 LIKE N'%not at this Trim station%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] double checkout rejected for the location reason', @Expected = N'1', @Actual = @ReasonOk;
GO

-- =============================================
-- Test 6: ShotCount exceeding the LOT piece count rejects (2026-07-06)
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');

DECLARE @L BIGINT;
CREATE TABLE #C6 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C6 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C6; DROP TABLE #C6;

DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #T6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T6 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 500, @DestinationCellLocationId = @LocB,
    @SourceLocationId = @LocA, @AppUserId = 1;  -- 500 > PieceCount 20
SELECT @S = Status, @M = Message FROM #T6; DROP TABLE #T6;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] ShotCount above LOT piece count rejected', @Expected = N'0', @Actual = @SStr;

DECLARE @ReasonOk NVARCHAR(10) = CASE WHEN @M LIKE N'%exceeds the LOT piece count%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] ShotCount cap rejected for the piece-count reason', @Expected = N'1', @Actual = @ReasonOk;
GO

-- =============================================
-- Test 7: ScrapCount exceeding the LOT piece count rejects (2026-07-06)
-- =============================================
DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id DESC);

DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #T7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T7 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @ScrapCount = 500, @DestinationCellLocationId = @LocB,
    @SourceLocationId = @LocA, @AppUserId = 1;  -- scrap 500 > PieceCount 20
SELECT @S = Status, @M = Message FROM #T7; DROP TABLE #T7;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] ScrapCount above LOT piece count rejected', @Expected = N'0', @Actual = @SStr;

DECLARE @ReasonOk NVARCHAR(10) = CASE WHEN @M LIKE N'%exceeds the LOT piece count%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] ScrapCount cap rejected for the piece-count reason', @Expected = N'1', @Actual = @ReasonOk;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
