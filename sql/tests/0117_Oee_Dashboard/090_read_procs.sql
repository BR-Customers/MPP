-- =============================================
-- File:         0117_Oee_Dashboard/090_read_procs.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  The dashboard's detail reads (OEE dashboard spec v0.3.2 sec
--               5.2-5.4, 6.7): Dashboard_GetTrend, _GetBreakdown,
--               _GetDowntimeByReason, _GetScrap, _GetDowntimeEntries.
--               The 050_unit_summary fixture (shift A Mon 2030-03-04, B Tue),
--               plus: Machine-Shop scrap 4 on the split line MA-L, and two
--               10-minute approximate planned entries on the plain line MA-P.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/090_read_procs.sql';
GO

-- ---- cleanup (FK-safe) ----
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name LIKE N'TEST_RP_%');
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
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_RP_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_RP_%';
GO

-- ---- fixture ----
EXEC test.OeeDashFixture_Build;
GO
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_RP_Day', N'Day 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT Id, '2030-03-04T07:01:00', '2030-03-04T15:01:00', N'TEST_RP_A' FROM Oee.ShiftSchedule WHERE Name = N'TEST_RP_Day'
UNION ALL
SELECT Id, '2030-03-05T07:01:00', '2030-03-05T15:01:00', N'TEST_RP_B' FROM Oee.ShiftSchedule WHERE Name = N'TEST_RP_Day';

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
DECLARE @A    BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @B    BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_B');
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
VALUES (N'ZZ-DSH-FG1', @Fg, @Mfg, @Good, 24, 24, @P, 1, @d0900, @P, (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A'), 24);
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


-- ---- additions for this file ----
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, ChargeToPartyId, IsNonRejectScrap)
SELECT N'ZZ-DSH-D-MS', N'DSH machine-shop defect', NULL, 0, SYSUTCDATETIME(), p.Id, 0
FROM Quality.ChargeToParty p WHERE p.Code = N'MachineShop';
DECLARE @A   BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @P   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-P');
DECLARE @Pln BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'ZZ-DSH-PLN');
DECLARE @Op  BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-DSH-CAST');
DECLARE @St  DATETIME2(3) = CAST(CAST('2030-03-04T07:01:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
INSERT INTO Workorder.RejectEvent (DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks)
SELECT dc.Id, 4, 1, DATEADD(HOUR, 2, @St), @Cast, @A, @L, N'ZZ-DSH ms on line' FROM Quality.DefectCode dc WHERE dc.Code = N'ZZ-DSH-D-MS';
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
VALUES (@P, @Pln, @A, @St, DATEADD(MINUTE, 10, @St), @Op, N'ZZ-DSH approx 1', 1, 10),
       (@P, @Pln, @A, @St, DATEADD(MINUTE, 10, @St), @Op, N'ZZ-DSH approx 2', 1, 10);
GO

-- =============================================
-- Trend
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @T TABLE (ProductionDay DATE, DayLabel NVARCHAR(20), Availability DECIMAL(5,4), Quality DECIMAL(5,4), AvailabilityBand NVARCHAR(10), QualityBand NVARCHAR(10));
INSERT INTO @T EXEC Oee.Dashboard_GetTrend @AnchorShiftId = @A;
DECLARE @v NVARCHAR(200), @e NVARCHAR(200);
SET @v = CAST((SELECT COUNT(*) FROM @T) AS NVARCHAR(10)) + N'/' + CAST((SELECT COUNT(*) FROM @T WHERE Availability IS NULL) AS NVARCHAR(10))
       + N'/' + (SELECT TOP 1 DayLabel FROM @T ORDER BY ProductionDay DESC);
EXEC test.Assert_IsEqual @TestName = N'[Trend] 7 rows ending at the anchor day, gap days NULL', @Expected = N'7/6/Mon 3/4', @Actual = @v;

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
INSERT INTO #Sum EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Day', @AnchorShiftId = @A;
SET @e = (SELECT CAST(Availability AS NVARCHAR(10)) + N'|' + CAST(Quality AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Plant');
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) + N'|' + CAST(Quality AS NVARCHAR(10)) FROM @T WHERE DayLabel = N'Mon 3/4');
EXEC test.Assert_IsEqual @TestName = N'[Trend] equals GetUnitSummary Day for that day (plant)', @Expected = @e, @Actual = @v;
SET @e = (SELECT CAST(Availability AS NVARCHAR(10)) FROM #Sum WHERE RowKind = N'Area' AND AreaFamily = N'diecast');
DELETE FROM @T;
INSERT INTO @T EXEC Oee.Dashboard_GetTrend @AnchorShiftId = @A, @AreaFamily = N'diecast';
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @T WHERE DayLabel = N'Mon 3/4');
EXEC test.Assert_IsEqual @TestName = N'[Trend] equals GetUnitSummary Day for that day (diecast area)', @Expected = @e, @Actual = @v;
DROP TABLE #Sum;
GO

-- =============================================
-- Breakdown
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @B TABLE (ChildZoom NVARCHAR(5), ChildAnchorShiftId BIGINT, Label NVARCHAR(60), BaseMinutes INT, DowntimeMinutes DECIMAL(12,2),
                  Availability DECIMAL(5,4), Good BIGINT, Scrap BIGINT, Quality DECIMAL(5,4), AvailabilityBand NVARCHAR(10), QualityBand NVARCHAR(10));
DECLARE @v NVARCHAR(200), @e NVARCHAR(200);
INSERT INTO @B EXEC Oee.Dashboard_GetBreakdown @Zoom = N'Day', @AnchorShiftId = @A, @LocationId = @M1;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'|' + MAX(ChildZoom) + N'|' + CAST(MAX(Availability) AS NVARCHAR(10)) FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[Breakdown] Day -> one Shift row per shift of the day (M1 0.5000)', @Expected = N'1|Shift|0.5000', @Actual = @v;
DELETE FROM @B;
INSERT INTO @B EXEC Oee.Dashboard_GetBreakdown @Zoom = N'Week', @AnchorShiftId = @A, @LocationId = @M1;
SET @v = CAST((SELECT COUNT(*) FROM @B) AS NVARCHAR(10)) + N'|' + (SELECT TOP 1 Label FROM @B) + N'|'
       + CAST((SELECT COUNT(*) FROM @B WHERE ChildAnchorShiftId IS NOT NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Breakdown] Week -> seven Day rows Mon..Sun, two with shifts', @Expected = N'7|Mon 3/4|2', @Actual = @v;
DELETE FROM @B;
INSERT INTO @B EXEC Oee.Dashboard_GetBreakdown @Zoom = N'Shift', @AnchorShiftId = @A, @LocationId = @M1;
DECLARE @n INT = (SELECT COUNT(*) FROM @B);
EXEC test.Assert_RowCount @TestName = N'[Breakdown] Shift zoom -> no rows', @ExpectedCount = 0, @ActualCount = @n;
GO

-- =============================================
-- Downtime by reason
-- =============================================
DECLARE @A  BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @L  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @P  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-P');
DECLARE @R TABLE (ReasonCodeId BIGINT, ReasonCode NVARCHAR(50), ReasonDescription NVARCHAR(500), ReasonTypeName NVARCHAR(100),
                  IsPlanned BIT, IsNoReason BIT, Minutes DECIMAL(12,2), EventCount INT);
DECLARE @v NVARCHAR(200);
INSERT INTO @R EXEC Oee.Dashboard_GetDowntimeByReason @Zoom = N'Shift', @AnchorShiftId = @A, @LocationId = @M1;
SET @v = (SELECT CAST(Minutes AS NVARCHAR(20)) + N'|' + CAST(IsPlanned AS NVARCHAR(1)) FROM @R WHERE IsNoReason = 1)
       + N'/' + (SELECT TOP 1 ReasonCode FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Reason] NULL reason as its own IsNoReason row (60, unplanned); Pareto order', @Expected = N'60.00|0/ZZ-DSH-PLN', @Actual = @v;
DELETE FROM @R;
INSERT INTO @R EXEC Oee.Dashboard_GetDowntimeByReason @Zoom = N'Shift', @AnchorShiftId = @A, @LocationId = @L;
SET @v = (SELECT CAST(SUM(Minutes) AS NVARCHAR(20)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Reason] station entries included for a line (station A 60)', @Expected = N'60.00', @Actual = @v;
DELETE FROM @R;
INSERT INTO @R EXEC Oee.Dashboard_GetDowntimeByReason @Zoom = N'Shift', @AnchorShiftId = @A, @LocationId = @P;
SET @v = (SELECT CAST(Minutes AS NVARCHAR(20)) + N'|' + CAST(EventCount AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Reason] two approximate entries at the shift start summed (20, 2)', @Expected = N'20.00|2', @Actual = @v;
GO

-- =============================================
-- Scrap
-- =============================================
DECLARE @A  BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @L  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @TP BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-P1');
DECLARE @S TABLE (GroupKey NVARCHAR(60), DefectCode NVARCHAR(50), DefectDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(100),
                  LocationId BIGINT, LocationName NVARCHAR(200), Good BIGINT, Quantity BIGINT, IsNonReject BIT, IsFoundDownstream BIT,
                  ChargedToFamily NVARCHAR(10), FoundAtLocationName NVARCHAR(200), Quality DECIMAL(5,4));
DECLARE @v NVARCHAR(200);
-- a trim press reads its shop: part, good 30, trim scrap 3
INSERT INTO @S EXEC Oee.Dashboard_GetScrap @Zoom = N'Shift', @AnchorShiftId = @A, @LocationId = @TP, @GroupBy = N'Part';
SET @v = (SELECT PartNumber + N'|' + CAST(Good AS NVARCHAR(10)) + N'|' + CAST(Quantity AS NVARCHAR(10)) + N'|' + CAST(Quality AS NVARCHAR(10)) + N'|' + DefectCode FROM @S);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] Part grouping per trim shop gives per-part quality', @Expected = N'ZZ-DSH-CAST|30|3|0.9091|ZZ-DSH-D-TS', @Actual = @v;
DELETE FROM @S;
INSERT INTO @S EXEC Oee.Dashboard_GetScrap @Zoom = N'Shift', @AnchorShiftId = @A, @AreaFamily = N'ma', @GroupBy = N'Line';
SET @v = (SELECT LocationName + N'|' + CAST(Quantity AS NVARCHAR(10)) + N'|' + DefectCode FROM @S);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] Line grouping lists the M&A line with its top defect', @Expected = N'DSH Split Line|4|ZZ-DSH-D-MS', @Actual = @v;
DELETE FROM @S;
INSERT INTO @S EXEC Oee.Dashboard_GetScrap @Zoom = N'Shift', @AnchorShiftId = @A, @LocationId = @L, @GroupBy = N'Defect';
SET @v = (SELECT CAST(Quantity AS NVARCHAR(10)) + N'|' + ChargedToFamily FROM @S WHERE IsFoundDownstream = 1)
       + N'/' + (SELECT CAST(Quantity AS NVARCHAR(10)) + N'|' + ChargedToFamily FROM @S WHERE IsFoundDownstream = 0);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] unit view: found-here-charged-to-DC flagged (greyed), own scrap not', @Expected = N'2|diecast/4|ma', @Actual = @v;
GO

-- =============================================
-- Downtime entries
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RP_A');
DECLARE @P BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-P');
DECLARE @L BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @E TABLE (DowntimeEventId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200), IsStation BIT, Minutes DECIMAL(12,2),
                  IsApproximate BIT, ReasonCode NVARCHAR(50), ReasonTypeName NVARCHAR(100), IsPlanned BIT, ByInitials NVARCHAR(10), StartedAtEt DATETIME2(3));
DECLARE @v NVARCHAR(200);
INSERT INTO @E EXEC Oee.Dashboard_GetDowntimeEntries @AnchorShiftId = @A, @LocationId = @P;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'|' + CAST(MIN(CAST(IsApproximate AS INT)) AS NVARCHAR(1)) + N'|' + CAST(SUM(Minutes) AS NVARCHAR(20)) FROM @E);
EXEC test.Assert_IsEqual @TestName = N'[Entries] Approximate flag and duration pass through', @Expected = N'2|1|20.00', @Actual = @v;
DELETE FROM @E;
INSERT INTO @E EXEC Oee.Dashboard_GetDowntimeEntries @AnchorShiftId = @A, @LocationId = @L;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'|' + CAST(MAX(CAST(IsStation AS INT)) AS NVARCHAR(1)) FROM @E);
EXEC test.Assert_IsEqual @TestName = N'[Entries] a line lists its stations'' entries, flagged IsStation', @Expected = N'1|1', @Actual = @v;
GO

-- ---- cleanup ----
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name LIKE N'TEST_RP_%');
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
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_RP_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_RP_%';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
