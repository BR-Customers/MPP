-- =============================================
-- File:         0117_Oee_Dashboard/050_unit_summary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  Oee.Dashboard_GetUnitSummary (OEE dashboard spec
--               docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--               sec 6.3, 8): one row per Unit / Station / Group / Area / Plant
--               for a period, POOLED never averaged.
--
--               Fixture (ZZ-DSH plant), shift A Mon 2030-03-04 07:01-15:01
--               (480 min) and shift B Tue 2030-03-05 07:01-15:01:
--                 M1  planned 07:01-13:01 (360) + unplanned no-reason 13:01-14:01
--                     (60)  -> base 120, 60/120 = 0.5000; 20 cast; DC scrap 5
--                 M2  no downtime -> 1.0000; 100 cast in A (die X at 09:00,
--                     die Y at 11:00), 50 in B
--                 Die cast area, shift A: (60 + 480) / (120 + 480) = 0.9000
--                     (averaging the two would say 0.7500)
--                 MA-L  station A down 07:01-08:01 -> A 0.8750, MI 1.0000,
--                       line = mean 0.9375; DC-coded scrap 2 found on it
--                 MA-P  plain line, 24 FG made -> 1.0000
--                 M&A area: (480*0.9375 + 480) / 960 = 0.9688
--                 Trim shop: 30 good at the shop, 3 trim scrap -> 0.9091;
--                       trim press tiles carry no quality
--                 Inspection line: nothing -> HasProduction 0, availability NULL
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/050_unit_summary.sql';
GO

-- ---- cleanup (FK-safe) ----
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name LIKE N'TEST_US_%');
DELETE FROM Workorder.RejectEvent         WHERE Remarks LIKE N'ZZ-DSH%';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Workorder.ProductionEvent     WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Lots.Lot                      WHERE LotName LIKE N'ZZ-DSH%';
DELETE FROM Parts.Item                    WHERE PartNumber LIKE N'ZZ-DSH%';
DELETE FROM Quality.DefectCode            WHERE Code LIKE N'ZZ-DSH-%';
DELETE FROM Tools.ToolAssignment          WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'ZZ-DSH%');
DELETE FROM Tools.Tool                    WHERE Code LIKE N'ZZ-DSH%';
EXEC test.OeeDashFixture_Teardown;
DELETE FROM Oee.DowntimeReasonCode        WHERE Code LIKE N'ZZ-DSH%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_US_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_US_%';
GO

-- ---- fixture ----
EXEC test.OeeDashFixture_Build;
GO
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_US_Day', N'Day 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT Id, '2030-03-04T07:01:00', '2030-03-04T15:01:00', N'TEST_US_A' FROM Oee.ShiftSchedule WHERE Name = N'TEST_US_Day'
UNION ALL
SELECT Id, '2030-03-05T07:01:00', '2030-03-05T15:01:00', N'TEST_US_B' FROM Oee.ShiftSchedule WHERE Name = N'TEST_US_Day';

INSERT INTO Oee.DowntimeReasonCode (Code, Description, OperationCategoryId, DowntimeReasonTypeId, IsExcused, CreatedByUserId)
VALUES (N'ZZ-DSH-PLN', N'DSH planned', NULL, (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break'), 1, 1);

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, ChargeToPartyId, IsNonRejectScrap)
SELECT v.Code, N'DSH test defect', NULL, 0, SYSUTCDATETIME(), p.Id, 0
FROM (VALUES (N'ZZ-DSH-D-DC', N'DieCast'), (N'ZZ-DSH-D-TS', N'TrimShop')) v (Code, Party)
INNER JOIN Quality.ChargeToParty p ON p.Code = v.Party;

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'Component'),    N'ZZ-DSH-CAST', N'DSH casting', 1, SYSUTCDATETIME(), 1),
       ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'ZZ-DSH-FG',   N'DSH finished good', 1, SYSUTCDATETIME(), 1);

INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId)
SELECT v.Code, N'DSH die', (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id),
       (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1
FROM (VALUES (N'ZZ-DSH-DIE-X'), (N'ZZ-DSH-DIE-Y')) v (Code);
GO

DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-DSH-CAST');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-DSH-FG');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @A    BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_A');
DECLARE @B    BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_B');
DECLARE @M1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @M2   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M2');
DECLARE @TR   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR');
DECLARE @TrT  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1');
DECLARE @L    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @LA   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-A');
DECLARE @P    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-P');
DECLARE @Src  BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftAttributionSource ORDER BY Id);
DECLARE @Op   BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Pln  BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'ZZ-DSH-PLN');
DECLARE @X    BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DSH-DIE-X');
DECLARE @Y    BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DSH-DIE-Y');
DECLARE @TrimOut BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE oty.Code = N'TrimOut' ORDER BY ot.Id);

-- Local wall clock on 2030-03-04/05 as UTC.
DECLARE @d0701 DATETIME2(3) = CAST(CAST('2030-03-04T07:01:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @d0801 DATETIME2(3) = DATEADD(HOUR, 1, @d0701);
DECLARE @d0900 DATETIME2(3) = DATEADD(MINUTE, 119, @d0701);
DECLARE @d1100 DATETIME2(3) = DATEADD(MINUTE, 239, @d0701);
DECLARE @d1301 DATETIME2(3) = DATEADD(HOUR, 6, @d0701);
DECLARE @d1401 DATETIME2(3) = DATEADD(HOUR, 7, @d0701);
DECLARE @e0900 DATETIME2(3) = DATEADD(DAY, 1, @d0900);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId)
VALUES (N'ZZ-DSH-DC1', @Cast, @Mfg, @Good, 170, 170, @M1, 1, @d0900, @M1),
       (N'ZZ-DSH-TR1', @Cast, @Mfg, @Good, 60, 60, @TrT, 1, @d0900, @M1);
-- A finished-good LOT carries the shift it was minted in + the minted quantity (spec v0.3.1 D18, D21).
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId, ShiftId, MintedPieceCount)
VALUES (N'ZZ-DSH-FG1', @Fg, @Mfg, @Good, 24, 24, @P, 1, @d0900, @P, (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_A'), 24);
DECLARE @Dc1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'ZZ-DSH-DC1');
DECLARE @Tr1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'ZZ-DSH-TR1');

-- Dies on M2: X until 10:00, then Y.
INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, ReleasedAt, AssignedByUserId)
VALUES (@X, @M2, DATEADD(HOUR, -1, @d0701), DATEADD(MINUTE, 179, @d0701), 1),
       (@Y, @M2, DATEADD(MINUTE, 179, @d0701), NULL, 1);

INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShiftAttributionSourceId)
VALUES (@Dc1, @A, 20, 1, @d0900, @M1, @Src),
       (@Dc1, @A, 60, 1, @d0900, @M2, @Src),
       (@Dc1, @A, 40, 1, @d1100, @M2, @Src),
       (@Dc1, @B, 50, 1, @e0900, @M2, @Src);

INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId, TerminalLocationId, ShiftId)
VALUES (@Tr1, @TrimOut, @d0900, 30, 1, @TrT, @A);

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES (@M1, @Pln, @A, @d0701, @d1301, @Op, N'ZZ-DSH planned'),
       (@M1, NULL, @A, @d1301, @d1401, @Op, N'ZZ-DSH no reason'),
       (@LA, NULL, @A, @d0701, @d0801, @Op, N'ZZ-DSH station A');

INSERT INTO Workorder.RejectEvent (DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks)
SELECT dc.Id, v.Qty, 1, @d0900, @Cast, @A, v.Cell, v.Remarks
FROM (VALUES (N'ZZ-DSH-D-DC', 5, @M1, N'ZZ-DSH dc at M1'),
             (N'ZZ-DSH-D-DC', 2, @L,  N'ZZ-DSH dc on line'),
             (N'ZZ-DSH-D-TS', 3, @TR, N'ZZ-DSH ts at shop')) v (Code, Qty, Cell, Remarks)
INNER JOIN Quality.DefectCode dc ON dc.Code = v.Code;
GO

-- ---- v2.0 (spec v0.3.1 6.7): shift A is STORED; shift B is left unstored, so
-- every Day/Week assertion below mixes a stored shift with a live one ----
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_A');
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @st EXEC Oee.ShiftSummary_Compute @ShiftId = @A, @AppUserId = 1;
GO

-- ---- capture helper: the proc's result shape ----
IF OBJECT_ID(N'tempdb..#Sum') IS NOT NULL DROP TABLE #Sum;
CREATE TABLE #Sum (
    RowKind NVARCHAR(10), AreaFamily NVARCHAR(10), ProductionAreaId BIGINT, ProductionAreaName NVARCHAR(200),
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200), ParentLocationId BIGINT,
    BaseMinutes INT, EffectiveUnplannedMinutes DECIMAL(12,2),
    DowntimeMinutes DECIMAL(12,2), PlannedDowntimeMinutes DECIMAL(12,2), UnplannedDowntimeMinutes DECIMAL(12,2),
    Availability DECIMAL(5,4), AvailabilityBand NVARCHAR(10),
    Good BIGINT, Scrap BIGINT, NonRejectScrap BIGINT, FoundDownstreamScrap BIGINT, UnplacedScrap BIGINT,
    Quality DECIMAL(5,4), QualityBand NVARCHAR(10),
    NoReasonCount INT, NoReasonMinutes DECIMAL(12,2), LastToolCode NVARCHAR(50),
    HasProduction BIT, IncludesInProgressShift BIT, SortKey INT);
GO

-- =============================================
-- Test 1: Shift zoom, shift A
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_A');
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @A;
DECLARE @v NVARCHAR(50);

SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M1');
EXEC test.Assert_IsEqual @TestName = N'[Summary] M1 2-hour base at 50% -> 0.5000', @Expected = N'0.5000', @Actual = @v;
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Group' AND ProductionAreaName = N'DSH Die Cast');
EXEC test.Assert_IsEqual @TestName = N'[Summary] pooled not averaged: die cast group 540/600 = 0.9000', @Expected = N'0.9000', @Actual = @v;

SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-MA-L');
EXEC test.Assert_IsEqual @TestName = N'[Summary] roll-up line = mean of its stations 0.9375', @Expected = N'0.9375', @Actual = @v;
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Group' AND ProductionAreaName = N'DSH M and A');
EXEC test.Assert_IsEqual @TestName = N'[Summary] roll-up line pools effective minutes: M&A group 930/960 = 0.9688', @Expected = N'0.9688', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Station' AND ParentLocationId = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L'));
EXEC test.Assert_IsEqual @TestName = N'[Summary] the line''s two stations are Station rows', @Expected = N'2', @Actual = @v;

SET @v = (SELECT CAST(HasProduction AS NVARCHAR(1)) + N'|' + ISNULL(CAST(Availability AS NVARCHAR(10)), N'<NULL>') FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-IN-L');
EXEC test.Assert_IsEqual @TestName = N'[Summary] no-production unit -> HasProduction 0, Availability NULL', @Expected = N'0|<NULL>', @Actual = @v;

SET @v = (SELECT CAST(NoReasonCount AS NVARCHAR(10)) + N'|' + CAST(NoReasonMinutes AS NVARCHAR(20)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M1');
EXEC test.Assert_IsEqual @TestName = N'[Summary] NULL-reason event -> NoReasonCount 1, 60 minutes', @Expected = N'1|60.00', @Actual = @v;
SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(20)) + N'|' + CAST(PlannedDowntimeMinutes AS NVARCHAR(20)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M1');
EXEC test.Assert_IsEqual @TestName = N'[Summary] the no-reason minutes count as unplanned', @Expected = N'60.00|360.00', @Actual = @v;

SET @v = (SELECT CAST(Quality AS NVARCHAR(10)) + N'|' + CAST(Good AS NVARCHAR(10)) + N'|' + CAST(Scrap AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Group' AND ProductionAreaName = N'DSH Trim Shop');
EXEC test.Assert_IsEqual @TestName = N'[Summary] trim scrap on the shop Group: 30/33 = 0.9091', @Expected = N'0.9091|30|3', @Actual = @v;
SET @v = (SELECT ISNULL(CAST(Quality AS NVARCHAR(10)), N'<NULL>') + N'|' + ISNULL(CAST(Good AS NVARCHAR(10)), N'<NULL>') FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-TR-P1');
EXEC test.Assert_IsEqual @TestName = N'[Summary] trim press Unit quality NULL', @Expected = N'<NULL>|<NULL>', @Actual = @v;

SET @v = (SELECT CAST(Scrap AS NVARCHAR(10)) + N'|' + CAST(FoundDownstreamScrap AS NVARCHAR(10)) + N'|' + CAST(Good AS NVARCHAR(10)) + N'|' + CAST(Quality AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Area' AND AreaFamily = N'diecast');
EXEC test.Assert_IsEqual @TestName = N'[Summary] DC-charged found on line is in the diecast Area: scrap 7, 2 downstream, 120 good, 0.9449', @Expected = N'7|2|120|0.9449', @Actual = @v;
SET @v = (SELECT CAST(Scrap AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-MA-L');
EXEC test.Assert_IsEqual @TestName = N'[Summary] ... and not on the line it was found on', @Expected = N'0', @Actual = @v;
SET @v = (SELECT CAST(Scrap AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Group' AND ProductionAreaName = N'DSH Die Cast');
EXEC test.Assert_IsEqual @TestName = N'[Summary] ... and not in any die cast Group', @Expected = N'5', @Actual = @v;

SET @v = (SELECT LastToolCode FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Summary] two dies -> latest only', @Expected = N'ZZ-DSH-DIE-Y', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Sum WHERE LocationCode = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Summary] two dies -> one row', @Expected = N'1', @Actual = @v;

SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Plant');
EXEC test.Assert_IsEqual @TestName = N'[Summary] one Plant row', @Expected = N'1', @Actual = @v;
GO

-- =============================================
-- Test 2: Week zoom = sum of its days; filter; unknown anchor
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_A');
DECLARE @B BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_B');
DECLARE @v NVARCHAR(50), @dayA BIGINT, @dayB BIGINT, @wk BIGINT;

TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Day', @AnchorShiftId = @A;
SET @dayA = (SELECT Good FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Day', @AnchorShiftId = @B;
SET @dayB = (SELECT Good FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Week', @AnchorShiftId = @A;
SET @wk = (SELECT Good FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
SET @v = CAST(@dayA AS NVARCHAR(10)) + N'+' + CAST(@dayB AS NVARCHAR(10)) + N'=' + CAST(@wk AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Summary] Week zoom = sum of its Day rows', @Expected = N'100+50=150', @Actual = @v;

TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @A, @AreaFamily = N'trim';
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Sum WHERE RowKind <> N'Plant' AND AreaFamily <> N'trim');
EXEC test.Assert_IsEqual @TestName = N'[Summary] @AreaFamily filter keeps only that family', @Expected = N'0', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Plant');
EXEC test.Assert_IsEqual @TestName = N'[Summary] @AreaFamily filter keeps the Plant row', @Expected = N'1', @Actual = @v;

TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Day', @AnchorShiftId = -1;
DECLARE @n INT = (SELECT COUNT(*) FROM #Sum);
EXEC test.Assert_RowCount @TestName = N'[Summary] unknown anchor -> 0 rows', @ExpectedCount = 0, @ActualCount = @n;
GO

-- =============================================
-- Test 3: stored vs live (v2.0)
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_A');
DECLARE @B BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_US_B');
DECLARE @v NVARCHAR(50);

-- B has no stored rows: it is computed live
SET @v = CAST((SELECT COUNT(*) FROM Oee.ShiftSummary WHERE ShiftId = @B) AS NVARCHAR(10));
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @B;
SET @v = @v + N'/' + ISNULL((SELECT CAST(Good AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[Summary] ended shift with no stored rows -> computed live (M2 50 in B)', @Expected = N'0/50', @Actual = @v;

-- a closed, stored shift is READ from Oee.ShiftSummary, not recomputed:
-- doctor a stored count and the read shows it (then put it back)
DECLARE @M2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M2');
UPDATE Oee.ShiftSummary SET Good = Good + 1000 WHERE ShiftId = @A AND RowKind = N'Unit' AND LocationId = @M2;
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @A;
SET @v = (SELECT CAST(Good AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Summary] closed stored shift is read from Oee.ShiftSummary (doctored 100 + 1000)', @Expected = N'1100', @Actual = @v;
-- @ReadLive = 1 (the unit drill-down at Shift zoom) recomputes the stored shift
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @A, @AreaFamily = NULL, @ReadLive = 1;
SET @v = (SELECT CAST(Good AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Summary] @ReadLive = 1 at Shift zoom ignores the stored row (100, not the doctored 1100)', @Expected = N'100', @Actual = @v;
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Day', @AnchorShiftId = @A, @AreaFamily = NULL, @ReadLive = 1;
SET @v = (SELECT CAST(Good AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Unit' AND LocationCode = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Summary] @ReadLive is ignored above Shift zoom (Day still reads the stored 1100)', @Expected = N'1100', @Actual = @v;
UPDATE Oee.ShiftSummary SET Good = Good - 1000 WHERE ShiftId = @A AND RowKind = N'Unit' AND LocationId = @M2;

-- stored and live give identical rows for the same shift
IF OBJECT_ID(N'tempdb..#Stored') IS NOT NULL DROP TABLE #Stored;
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @A;
SELECT * INTO #Stored FROM #Sum;
DELETE FROM Oee.ShiftSummary WHERE ShiftId = @A;
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @A;
DECLARE @diff INT = (SELECT COUNT(*) FROM (SELECT * FROM #Stored EXCEPT SELECT * FROM #Sum) x)
                  + (SELECT COUNT(*) FROM (SELECT * FROM #Sum EXCEPT SELECT * FROM #Stored) y);
DECLARE @rows INT = (SELECT COUNT(*) FROM #Stored);
SET @v = CAST(@diff AS NVARCHAR(10)) + N'/' + CASE WHEN @rows > 0 THEN N'rows' ELSE N'empty' END;
EXEC test.Assert_IsEqual @TestName = N'[Summary] stored and live give identical rows for the same shift', @Expected = N'0/rows', @Actual = @v;
DROP TABLE #Stored;

-- an open shift is read live and flagged
DECLARE @OwnOpen BIT = 0;
IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
BEGIN
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
    SELECT Id, '2030-03-06T07:01:00', NULL, N'TEST_US_C' FROM Oee.ShiftSchedule WHERE Name = N'TEST_US_Day';
    SET @OwnOpen = 1;
END
DECLARE @C BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id);
TRUNCATE TABLE #Sum;
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @C;
SET @v = ISNULL((SELECT CAST(IncludesInProgressShift AS NVARCHAR(1)) FROM #Sum WHERE RowKind = N'Plant'), N'<none>')
       + N'/' + CAST((SELECT COUNT(*) FROM Oee.ShiftSummary WHERE ShiftId = @C) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Summary] open shift included live, IncludesInProgressShift 1, nothing stored', @Expected = N'1/0', @Actual = @v;
IF @OwnOpen = 1 DELETE FROM Oee.Shift WHERE Remarks = N'TEST_US_C';
GO

-- ---- cleanup ----
DROP TABLE #Sum;
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name LIKE N'TEST_US_%');
DELETE FROM Workorder.RejectEvent         WHERE Remarks LIKE N'ZZ-DSH%';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Workorder.ProductionEvent     WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Lots.Lot                      WHERE LotName LIKE N'ZZ-DSH%';
DELETE FROM Parts.Item                    WHERE PartNumber LIKE N'ZZ-DSH%';
DELETE FROM Quality.DefectCode            WHERE Code LIKE N'ZZ-DSH-%';
DELETE FROM Tools.ToolAssignment          WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'ZZ-DSH%');
DELETE FROM Tools.Tool                    WHERE Code LIKE N'ZZ-DSH%';
EXEC test.OeeDashFixture_Teardown;
DELETE FROM Oee.DowntimeReasonCode        WHERE Code LIKE N'ZZ-DSH%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_US_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_US_%';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
