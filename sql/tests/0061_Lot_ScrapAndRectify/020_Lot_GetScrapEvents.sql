-- =============================================
-- File:         0061_Lot_ScrapAndRectify/020_Lot_GetScrapEvents.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-19
-- Description:  Tests for Lots.Lot_GetScrapEvents (backlog 5.2 -- the per-event
--               scrap list behind the LOT Detail Scrap tab). Asserts:
--                 - a clean LOT returns an empty set (no invented 404 row)
--                 - one row per Workorder.RejectEvent, newest first
--                 - the defect code + description resolve
--                 - ChargeToArea (the LOT's location at scrap time) round-trips
--                 - the totals agree with Lots.Lot_GetScrapSummary
--
--               Scrap is recorded through Workorder.RejectEvent_Record with
--               @ChargeToArea set to the LOT's current location name -- exactly
--               what BlueRidge.Lots.Lot.recordScrapAtCurrentLocation does from
--               the LOT Detail Scrap tab. No new mutation proc is involved.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0061_Lot_ScrapAndRectify/020_Lot_GetScrapEvents.sql';
GO

IF OBJECT_ID(N'tempdb..#ScrapFix') IS NOT NULL DROP TABLE #ScrapFix;
CREATE TABLE #ScrapFix (Slot NVARCHAR(1) PRIMARY KEY, LotId BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- LOT A: scrapped twice. LOT B: clean (empty-set assertion).
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #ScrapFix (Slot, LotId) VALUES (N'A', (SELECT NewId FROM @cr));

DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #ScrapFix (Slot, LotId) VALUES (N'B', (SELECT NewId FROM @cr));
GO

-- =============================================
-- Test 1: a clean LOT returns an empty set.
-- =============================================
DECLARE @LotB BIGINT = (SELECT LotId FROM #ScrapFix WHERE Slot = N'B');
IF OBJECT_ID(N'tempdb..#Ev1') IS NOT NULL DROP TABLE #Ev1;
CREATE TABLE #Ev1 (RejectEventId BIGINT, RecordedAt DATETIME2(3), Quantity INT,
                   DefectCodeId BIGINT, DefectCode NVARCHAR(50), DefectDescription NVARCHAR(500),
                   DefectCategoryName NVARCHAR(200), ChargeToArea NVARCHAR(100),
                   Remarks NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO #Ev1 EXEC Lots.Lot_GetScrapEvents @LotId = @LotB;
DECLARE @n1 INT = (SELECT COUNT(*) FROM #Ev1);
EXEC test.Assert_RowCount @TestName = N'[ScrapEvents] clean LOT returns empty set',
    @ExpectedCount = 0, @ActualCount = @n1;
DROP TABLE #Ev1;
GO

-- =============================================
-- Test 2: two scraps against LOT A, charged to the LOT's current location.
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #ScrapFix WHERE Slot = N'A');
DECLARE @Area NVARCHAR(100) = (SELECT TOP 1 CAST(loc.Name AS NVARCHAR(100))
                               FROM Location.Location loc
                               INNER JOIN Lots.Lot l ON l.CurrentLocationId = loc.Id
                               WHERE l.Id = @LotA);
DECLARE @D1 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @D2 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL AND Id <> @D1 ORDER BY Id);

DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rr EXEC Workorder.RejectEvent_Record
    @LotId = @LotA, @DefectCodeId = @D1, @Quantity = 3,
    @ChargeToArea = @Area, @Remarks = N'LOT Detail scrap', @AppUserId = 1;
DECLARE @s2a BIT = (SELECT TOP 1 Status FROM @rr);
EXEC test.Assert_IsTrue @TestName = N'[ScrapEvents] first scrap recorded', @Condition = @s2a;

DELETE FROM @rr;
INSERT INTO @rr EXEC Workorder.RejectEvent_Record
    @LotId = @LotA, @DefectCodeId = @D2, @Quantity = 5,
    @ChargeToArea = @Area, @Remarks = N'LOT Detail scrap', @AppUserId = 1;
DECLARE @s2b BIT = (SELECT TOP 1 Status FROM @rr);
EXEC test.Assert_IsTrue @TestName = N'[ScrapEvents] second scrap recorded', @Condition = @s2b;
GO

-- =============================================
-- Test 3: the read returns both rows, newest first, with the code + area resolved.
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #ScrapFix WHERE Slot = N'A');
IF OBJECT_ID(N'tempdb..#Ev3') IS NOT NULL DROP TABLE #Ev3;
CREATE TABLE #Ev3 (RejectEventId BIGINT, RecordedAt DATETIME2(3), Quantity INT,
                   DefectCodeId BIGINT, DefectCode NVARCHAR(50), DefectDescription NVARCHAR(500),
                   DefectCategoryName NVARCHAR(200), ChargeToArea NVARCHAR(100),
                   Remarks NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200),
                   Ord INT IDENTITY(1,1));
INSERT INTO #Ev3 (RejectEventId, RecordedAt, Quantity, DefectCodeId, DefectCode,
                  DefectDescription, DefectCategoryName, ChargeToArea, Remarks, ByUserId, ByUserName)
    EXEC Lots.Lot_GetScrapEvents @LotId = @LotA;

DECLARE @n3 INT = (SELECT COUNT(*) FROM #Ev3);
EXEC test.Assert_RowCount @TestName = N'[ScrapEvents] two scrap rows returned',
    @ExpectedCount = 2, @ActualCount = @n3;

-- Newest first: the 5-piece scrap was recorded second.
DECLARE @firstQty INT = (SELECT Quantity FROM #Ev3 WHERE Ord = 1);
DECLARE @firstQtyStr NVARCHAR(20) = CAST(@firstQty AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[ScrapEvents] newest scrap first',
    @Expected = N'5', @Actual = @firstQtyStr;

DECLARE @blankCodes INT = (SELECT COUNT(*) FROM #Ev3 WHERE DefectCode IS NULL OR DefectCode = N'');
EXEC test.Assert_RowCount @TestName = N'[ScrapEvents] every row resolves a defect code',
    @ExpectedCount = 0, @ActualCount = @blankCodes;

DECLARE @Area NVARCHAR(100) = (SELECT TOP 1 CAST(loc.Name AS NVARCHAR(100))
                               FROM Location.Location loc
                               INNER JOIN Lots.Lot l ON l.CurrentLocationId = loc.Id
                               WHERE l.Id = @LotA);
DECLARE @areaRows INT = (SELECT COUNT(*) FROM #Ev3 WHERE ChargeToArea = @Area);
EXEC test.Assert_RowCount @TestName = N'[ScrapEvents] both rows charged to the LOT current location',
    @ExpectedCount = 2, @ActualCount = @areaRows;

DECLARE @blankUsers INT = (SELECT COUNT(*) FROM #Ev3 WHERE ByUserName IS NULL);
EXEC test.Assert_RowCount @TestName = N'[ScrapEvents] every row resolves the acting user',
    @ExpectedCount = 0, @ActualCount = @blankUsers;
DROP TABLE #Ev3;
GO

-- =============================================
-- Test 4: the events agree with the summary card, and the LOT was decremented
--         (subtractive -- the LOT Detail scrap passes no @OperationTypeCode).
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #ScrapFix WHERE Slot = N'A');
IF OBJECT_ID(N'tempdb..#Sum4') IS NOT NULL DROP TABLE #Sum4;
CREATE TABLE #Sum4 (RejectedTotal INT, CounterScrap INT, TotalScrap INT);
INSERT INTO #Sum4 EXEC Lots.Lot_GetScrapSummary @LotId = @LotA;

DECLARE @rt INT = (SELECT RejectedTotal FROM #Sum4);
DECLARE @rtStr NVARCHAR(20) = CAST(@rt AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[ScrapEvents] summary RejectedTotal is 8',
    @Expected = N'8', @Actual = @rtStr;

DECLARE @pc4 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotA);
DECLARE @pc4Str NVARCHAR(20) = CAST(@pc4 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[ScrapEvents] LOT decremented subtractively to 92',
    @Expected = N'92', @Actual = @pc4Str;
DROP TABLE #Sum4;
GO

-- =============================================
-- Test 5: the scrap shows in the LOT history timeline with its charged area.
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #ScrapFix WHERE Slot = N'A');
IF OBJECT_ID(N'tempdb..#Hist5') IS NOT NULL DROP TABLE #Hist5;
CREATE TABLE #Hist5 (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500),
                     ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO #Hist5 EXEC Lots.Lot_GetAttributeHistory @LotId = @LotA;

DECLARE @rej5 INT = (SELECT COUNT(*) FROM #Hist5 WHERE EventKind = N'Reject');
EXEC test.Assert_RowCount @TestName = N'[ScrapEvents] history carries 2 Reject rows',
    @ExpectedCount = 2, @ActualCount = @rej5;

DECLARE @det5 NVARCHAR(500) = (SELECT TOP 1 Detail FROM #Hist5 WHERE EventKind = N'Reject');
EXEC test.Assert_Contains @TestName = N'[ScrapEvents] history Detail names the charged area',
    @HaystackStr = @det5, @NeedleStr = N'charged to';
DROP TABLE #Hist5;
GO

-- ---- cleanup (FK-safe: child rows -> LOTs) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #ScrapFix;

DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#ScrapFix') IS NOT NULL DROP TABLE #ScrapFix;
GO

EXEC test.EndTestFile;
GO
