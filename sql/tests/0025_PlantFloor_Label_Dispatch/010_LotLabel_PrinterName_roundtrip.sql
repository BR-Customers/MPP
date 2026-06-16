-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/010_LotLabel_PrinterName_roundtrip.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 4 Spec 2: @PrinterName persists to LotLabel.PrinterName
--               on both LotLabel_Print and LotLabel_Reprint.
--               Fixture item = 1 (5G0) at DC1-M05; Received origin.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/010_LotLabel_PrinterName_roundtrip.sql';
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
DECLARE @NonInitial BIGINT = (SELECT TOP 1 Id FROM Lots.PrintReasonCode WHERE Code <> N'Initial' ORDER BY Id);

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

-- Print with a printer name
DECLARE @S BIT, @LabelId BIGINT;
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #P EXEC Lots.LotLabel_Print
    @LotId = @L, @LabelTypeCodeId = @Primary, @PrintReasonCodeId = @Initial,
    @AppUserId = 1, @PrinterName = N'DC1-PRN';
SELECT @S = Status, @LabelId = NewId FROM #P; DROP TABLE #P;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PrintName] Print Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @PName NVARCHAR(100) = (SELECT PrinterName FROM Lots.LotLabel WHERE Id = @LabelId);
EXEC test.Assert_IsEqual @TestName = N'[PrintName] PrinterName persisted on Print', @Expected = N'DC1-PRN', @Actual = @PName;

-- Reprint with a different printer name + non-Initial reason
DECLARE @S2 BIT, @LabelId2 BIGINT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #R EXEC Lots.LotLabel_Reprint
    @LotId = @L, @PrintReasonCodeId = @NonInitial, @AppUserId = 1, @PrinterName = N'DC1-PRN2';
SELECT @S2 = Status, @LabelId2 = NewId FROM #R; DROP TABLE #R;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PrintName] Reprint Status is 1', @Expected = N'1', @Actual = @S2Str;

DECLARE @PName2 NVARCHAR(100) = (SELECT PrinterName FROM Lots.LotLabel WHERE Id = @LabelId2);
EXEC test.Assert_IsEqual @TestName = N'[PrintName] PrinterName persisted on Reprint', @Expected = N'DC1-PRN2', @Actual = @PName2;
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
