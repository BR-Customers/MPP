-- =============================================
-- File:         0020_PlantFloor_Foundation/080_Lot_AssertNotBlocked.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Lots.Lot_AssertNotBlocked (B2 shared guard).
--               Good -> IsBlocked=0; Hold/Scrap/Closed -> IsBlocked=1 with
--               a message naming the status; non-existent lot -> IsBlocked=1
--               with 'LOT not found'.
--
--               Lot rows are inserted directly here (Lot_Create not under
--               test in this file). Item/Location/AppUser resolved from seeds.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/080_Lot_AssertNotBlocked.sql';
GO

-- ---- shared fixture: one Lot per status (Good/Hold/Scrap/Closed) ----
DELETE FROM Lots.Lot WHERE LotName IN
    (N'TEST-ANB-GOOD', N'TEST-ANB-HOLD', N'TEST-ANB-SCRAP', N'TEST-ANB-CLOSED');

DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @LocId  BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @UserId BIGINT = 1;
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES
    (N'TEST-ANB-GOOD',   @ItemId, @OriginId, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good'),   10, @LocId, @UserId),
    (N'TEST-ANB-HOLD',   @ItemId, @OriginId, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Hold'),   10, @LocId, @UserId),
    (N'TEST-ANB-SCRAP',  @ItemId, @OriginId, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Scrap'),  10, @LocId, @UserId),
    (N'TEST-ANB-CLOSED', @ItemId, @OriginId, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed'), 10, @LocId, @UserId);
GO

-- =============================================
-- Test 1: Good -> IsBlocked = 0
-- =============================================
DECLARE @LotId BIGINT, @B BIT, @BStr NVARCHAR(1);
SET @LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-ANB-GOOD');
CREATE TABLE #G (IsBlocked BIT, Message NVARCHAR(500));
INSERT INTO #G EXEC Lots.Lot_AssertNotBlocked @LotId = @LotId;
SELECT @B = IsBlocked FROM #G;
DROP TABLE #G;
SET @BStr = CAST(@B AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AnbGood] Good lot IsBlocked=0',
    @Expected = N'0',
    @Actual   = @BStr;
GO

-- =============================================
-- Test 2: Hold -> IsBlocked = 1 + message names the status
-- =============================================
DECLARE @LotId BIGINT, @B BIT, @BStr NVARCHAR(1), @M NVARCHAR(500);
SET @LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-ANB-HOLD');
CREATE TABLE #H (IsBlocked BIT, Message NVARCHAR(500));
INSERT INTO #H EXEC Lots.Lot_AssertNotBlocked @LotId = @LotId;
SELECT @B = IsBlocked, @M = Message FROM #H;
DROP TABLE #H;
SET @BStr = CAST(@B AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AnbHold] Hold lot IsBlocked=1',
    @Expected = N'1',
    @Actual   = @BStr;
EXEC test.Assert_Contains
    @TestName    = N'[AnbHold] Message names the Hold status',
    @HaystackStr = @M,
    @NeedleStr   = N'Hold';
GO

-- =============================================
-- Test 3: Scrap -> IsBlocked = 1 + message names the status
-- =============================================
DECLARE @LotId BIGINT, @B BIT, @BStr NVARCHAR(1), @M NVARCHAR(500);
SET @LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-ANB-SCRAP');
CREATE TABLE #S (IsBlocked BIT, Message NVARCHAR(500));
INSERT INTO #S EXEC Lots.Lot_AssertNotBlocked @LotId = @LotId;
SELECT @B = IsBlocked, @M = Message FROM #S;
DROP TABLE #S;
SET @BStr = CAST(@B AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AnbScrap] Scrap lot IsBlocked=1',
    @Expected = N'1',
    @Actual   = @BStr;
EXEC test.Assert_Contains
    @TestName    = N'[AnbScrap] Message names the Scrap status',
    @HaystackStr = @M,
    @NeedleStr   = N'Scrap';
GO

-- =============================================
-- Test 4: Closed -> IsBlocked = 1 (cannot advance a closed lot)
-- =============================================
DECLARE @LotId BIGINT, @B BIT, @BStr NVARCHAR(1), @M NVARCHAR(500);
SET @LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-ANB-CLOSED');
CREATE TABLE #C (IsBlocked BIT, Message NVARCHAR(500));
INSERT INTO #C EXEC Lots.Lot_AssertNotBlocked @LotId = @LotId;
SELECT @B = IsBlocked, @M = Message FROM #C;
DROP TABLE #C;
SET @BStr = CAST(@B AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AnbClosed] Closed lot IsBlocked=1',
    @Expected = N'1',
    @Actual   = @BStr;
EXEC test.Assert_Contains
    @TestName    = N'[AnbClosed] Message names the Closed status',
    @HaystackStr = @M,
    @NeedleStr   = N'Closed';
GO

-- =============================================
-- Test 5: Non-existent lot -> IsBlocked = 1 + 'LOT not found'
-- =============================================
DECLARE @B BIT, @BStr NVARCHAR(1), @M NVARCHAR(500);
CREATE TABLE #N (IsBlocked BIT, Message NVARCHAR(500));
INSERT INTO #N EXEC Lots.Lot_AssertNotBlocked @LotId = 9999999999;
SELECT @B = IsBlocked, @M = Message FROM #N;
DROP TABLE #N;
SET @BStr = CAST(@B AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AnbMissing] Non-existent lot IsBlocked=1',
    @Expected = N'1',
    @Actual   = @BStr;
EXEC test.Assert_Contains
    @TestName    = N'[AnbMissing] Message is LOT not found',
    @HaystackStr = @M,
    @NeedleStr   = N'LOT not found';
GO

-- cleanup
DELETE FROM Lots.Lot WHERE LotName IN
    (N'TEST-ANB-GOOD', N'TEST-ANB-HOLD', N'TEST-ANB-SCRAP', N'TEST-ANB-CLOSED');
GO

EXEC test.EndTestFile;
GO
