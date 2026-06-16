-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/020_LotLabel_RecordDispatch.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 4 Spec 2: Lots.LotLabel_RecordDispatch sets DispatchedAt
--               + PrinterName on the row (Status=1); a bad LotLabelId -> Status=0.
--               Fixture item = 1 (5G0) at DC1-M05; Received origin.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/020_LotLabel_RecordDispatch.sql';
GO

-- ---- fixture cleanup ----
DELETE FROM Lots.LotLabel WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Primary BIGINT = (SELECT TOP 1 Id FROM Lots.LabelTypeCode WHERE Code = N'Primary');
IF @Primary IS NULL SET @Primary = (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id);
DECLARE @Initial BIGINT = (SELECT Id FROM Lots.PrintReasonCode WHERE Code = N'Initial');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @LabelId BIGINT;
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #P EXEC Lots.LotLabel_Print
    @LotId = @L, @LabelTypeCodeId = @Primary, @PrintReasonCodeId = @Initial, @AppUserId = 1;
SELECT @LabelId = NewId FROM #P; DROP TABLE #P;

-- record dispatch
DECLARE @S BIT;
CREATE TABLE #D (Status BIT, Message NVARCHAR(500));
INSERT INTO #D EXEC Lots.LotLabel_RecordDispatch @LotLabelId = @LabelId, @PrinterName = N'DC1-PRN';
SELECT @S = Status FROM #D; DROP TABLE #D;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Dispatch] RecordDispatch Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @DispSet NVARCHAR(10) = (SELECT CASE WHEN DispatchedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.LotLabel WHERE Id = @LabelId);
EXEC test.Assert_IsEqual @TestName = N'[Dispatch] DispatchedAt set', @Expected = N'1', @Actual = @DispSet;

DECLARE @PName NVARCHAR(100) = (SELECT PrinterName FROM Lots.LotLabel WHERE Id = @LabelId);
EXEC test.Assert_IsEqual @TestName = N'[Dispatch] PrinterName set', @Expected = N'DC1-PRN', @Actual = @PName;

-- bad id -> Status 0
DECLARE @S2 BIT;
CREATE TABLE #D2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #D2 EXEC Lots.LotLabel_RecordDispatch @LotLabelId = 999999999, @PrinterName = N'X';
SELECT @S2 = Status FROM #D2; DROP TABLE #D2;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Dispatch] bad LotLabelId rejected', @Expected = N'0', @Actual = @S2Str;
GO

-- ---- cleanup ----
DELETE FROM Lots.LotLabel WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
