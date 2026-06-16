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
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = NULL, @AppUserId = 1;
SELECT @S = Status FROM #T1; DROP TABLE #T1;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] missing destination rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 2: non-eligible destination rejects
-- =============================================
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @BadLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL AND l.Id NOT IN (SELECT LocationId FROM Parts.v_EffectiveItemLocation WHERE ItemId = 1)
    ORDER BY l.Id);

DECLARE @S BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = @BadLoc, @AppUserId = 1;
SELECT @S = Status FROM #T2; DROP TABLE #T2;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] non-eligible destination rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: blocked (Hold) LOT rejects
-- =============================================
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @L;

DECLARE @S BIT;
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T3 EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 20, @DestinationCellLocationId = @LocB, @AppUserId = 1;
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
    @ParentLotId = @L, @OperationTemplateId = @OtId, @ShotCount = 3, @DestinationCellLocationId = @LocB, @AppUserId = 1;  -- 3 < prior 10
SELECT @S = Status FROM #T4; DROP TABLE #T4;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] counter regression rejected (D1)', @Expected = N'0', @Actual = @SStr;
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
