-- =============================================
-- File:         0117_Oee_Dashboard/060_shift_summary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  One shift's stored figures (OEE dashboard spec v0.3.1 sec 6.3,
--               6.7): Oee.ufn_ShiftSummaryRows (the calculation),
--               Oee.ufn_ShiftInputFingerprint, Oee.ShiftSummary_Compute and
--               Oee.ShiftSummary_RecomputeRange.
--
--               Same fixture as 050_unit_summary.sql (shift A Mon 2030-03-04
--               07:01-15:01, shift B Tue), whose expected figures are worked
--               out in that file's header:
--                 M1   base 120, 60 unplanned no-reason -> 0.5000; DC scrap 5
--                 M2   die X then Y in A -> last die Y
--                 MA-L roll-up: station A 0.8750, MI 1.0000 -> mean 0.9375,
--                      effective unplanned 480 * 0.0625 = 30; DC scrap 2 found
--                      on it (charged to Die Cast)
--                 Trim shop: 30 good + 3 trim scrap at the shop
--                 Inspection line: idle
--               Plus an open shift C (Wed) for the "never store the shift in
--               progress" rule.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/060_shift_summary.sql';
GO

-- ---- cleanup (FK-safe) ----
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name LIKE N'TEST_SS_%');
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
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SS_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SS_%';
GO

-- ---- fixture ----
EXEC test.OeeDashFixture_Build;
GO
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_SS_Day', N'Day 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT Id, '2030-03-04T07:01:00', '2030-03-04T15:01:00', N'TEST_SS_A' FROM Oee.ShiftSchedule WHERE Name = N'TEST_SS_Day'
UNION ALL
SELECT Id, '2030-03-05T07:01:00', '2030-03-05T15:01:00', N'TEST_SS_B' FROM Oee.ShiftSchedule WHERE Name = N'TEST_SS_Day';

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
DECLARE @A    BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_A');
DECLARE @B    BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_B');
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
VALUES (N'ZZ-DSH-FG1', @Fg, @Mfg, @Good, 24, 24, @P, 1, @d0900, @P, (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_A'), 24);
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


-- ---- an open shift C (only when no shift is open; one open shift max) ----
IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
    SELECT Id, '2030-03-06T07:01:00', NULL, N'TEST_SS_C' FROM Oee.ShiftSchedule WHERE Name = N'TEST_SS_Day';
GO

-- =============================================
-- Test 1: Oee.ufn_ShiftSummaryRows -- the calculation for shift A
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_A');
IF OBJECT_ID(N'tempdb..#R') IS NOT NULL DROP TABLE #R;
SELECT r.*, l.Code AS LocCode INTO #R
FROM Oee.ufn_ShiftSummaryRows(@A) r LEFT JOIN Location.Location l ON l.Id = r.LocationId;
DECLARE @v NVARCHAR(200), @e NVARCHAR(200);

SET @e = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@A) WHERE LocationCode = N'ZZ-DSH-DC-M1');
SET @v = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM #R WHERE RowKind = N'Unit' AND LocCode = N'ZZ-DSH-DC-M1');
EXEC test.Assert_IsEqual @TestName = N'[Rows] unit minutes equal ufn_ShiftAvailability (M1 base)', @Expected = @e, @Actual = @v;
SET @v = (SELECT CAST(PlannedMinutes AS NVARCHAR(10)) + N'/' + CAST(BaseMinutes AS NVARCHAR(10)) + N'/' + CAST(EffectiveUnplannedMinutes AS NVARCHAR(20))
          FROM #R WHERE RowKind = N'Unit' AND LocCode = N'ZZ-DSH-DC-M1');
EXEC test.Assert_IsEqual @TestName = N'[Rows] M1 planned 480, base 120, effective unplanned 60', @Expected = N'480/120/60.0000', @Actual = @v;

SET @v = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) + N'/' + CAST(EffectiveUnplannedMinutes AS NVARCHAR(20))
          FROM #R WHERE RowKind = N'Unit' AND LocCode = N'ZZ-DSH-MA-L');
EXEC test.Assert_IsEqual @TestName = N'[Rows] roll-up line EffectiveUnplanned = Base*(1-mean) = 480*0.0625', @Expected = N'480/30.0000', @Actual = @v;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #R WHERE RowKind = N'Station' AND ParentUnitLocationId = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L'));
EXEC test.Assert_IsEqual @TestName = N'[Rows] the line''s two stations get Station rows', @Expected = N'2', @Actual = @v;
SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(20)) FROM #R WHERE RowKind = N'Station' AND LocCode = N'ZZ-DSH-MA-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rows] station row carries its own entered minutes (60)', @Expected = N'60.00', @Actual = @v;

SET @v = (SELECT CAST(Scrap AS NVARCHAR(10)) FROM #R WHERE RowKind = N'Unit' AND LocCode = N'ZZ-DSH-MA-L');
EXEC test.Assert_IsEqual @TestName = N'[Rows] DC-charged scrap found on line is not on the line Unit', @Expected = N'0', @Actual = @v;
SET @v = (SELECT CAST(Scrap AS NVARCHAR(10)) + N'/' + CAST(FoundDownstreamScrap AS NVARCHAR(10)) FROM #R WHERE RowKind = N'AreaCharge' AND AreaFamily = N'diecast');
EXEC test.Assert_IsEqual @TestName = N'[Rows] DC-charged scrap found on line -> AreaCharge diecast (5 at M1 + 2 downstream)', @Expected = N'7/2', @Actual = @v;

SET @v = (SELECT CAST(Good AS NVARCHAR(10)) + N'/' + CAST(Scrap AS NVARCHAR(10)) FROM #R WHERE RowKind = N'AreaPlacement' AND LocCode = N'ZZ-DSH-TR');
EXEC test.Assert_IsEqual @TestName = N'[Rows] trim good + scrap on the AreaPlacement shop row', @Expected = N'30/3', @Actual = @v;
SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(10)) + N'/' + CAST(SUM(Scrap) AS NVARCHAR(10)) FROM #R WHERE RowKind = N'Unit' AND AreaFamily = N'trim');
EXEC test.Assert_IsEqual @TestName = N'[Rows] trim press Unit Good/Scrap 0', @Expected = N'0/0', @Actual = @v;
SET @v = (SELECT CAST(MIN(CAST(IsActive AS INT)) AS NVARCHAR(1)) FROM #R WHERE RowKind = N'Unit' AND AreaFamily = N'trim');
EXEC test.Assert_IsEqual @TestName = N'[Rows] trim presses active when their shop made something', @Expected = N'1', @Actual = @v;

SET @v = (SELECT CAST(IsActive AS NVARCHAR(1)) FROM #R WHERE RowKind = N'Unit' AND LocCode = N'ZZ-DSH-IN-L');
EXEC test.Assert_IsEqual @TestName = N'[Rows] idle unit IsActive 0', @Expected = N'0', @Actual = @v;

SET @v = (SELECT CAST(NoReasonCount AS NVARCHAR(10)) + N'/' + CAST(NoReasonMinutes AS NVARCHAR(20)) + N'/' + CAST(UnplannedDowntimeMinutes AS NVARCHAR(20))
          FROM #R WHERE RowKind = N'Unit' AND LocCode = N'ZZ-DSH-DC-M1');
EXEC test.Assert_IsEqual @TestName = N'[Rows] NULL-reason entry -> NoReasonCount 1, in Unplanned', @Expected = N'1/60.00/60.00', @Actual = @v;

SET @v = (SELECT t.Code FROM #R r INNER JOIN Tools.Tool t ON t.Id = r.LastToolId WHERE r.RowKind = N'Unit' AND r.LocCode = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Rows] two dies -> LastToolId = latest (Y)', @Expected = N'ZZ-DSH-DIE-Y', @Actual = @v;

SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ShiftSummaryRows(-1));
EXEC test.Assert_IsEqual @TestName = N'[Rows] unknown shift -> no rows', @Expected = N'0', @Actual = @v;
DROP TABLE #R;
GO

-- =============================================
-- Test 2: Compute stores, replaces, refuses the open shift
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_A');
DECLARE @C BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id);
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @v NVARCHAR(200), @e NVARCHAR(200);

INSERT INTO @st EXEC Oee.ShiftSummary_Compute @ShiftId = @A, @AppUserId = 1;
SET @v = (SELECT CAST(Status AS NVARCHAR(1)) FROM @st);
EXEC test.Assert_IsEqual @TestName = N'[Compute] closed shift -> Status 1', @Expected = N'1', @Actual = @v;
SET @e = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ShiftSummaryRows(@A));
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ShiftSummary WHERE ShiftId = @A);
EXEC test.Assert_IsEqual @TestName = N'[Compute] stores every computed row', @Expected = @e, @Actual = @v;
DECLARE @fp VARBINARY(32) = (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@A));
DECLARE @bad INT = (SELECT COUNT(*) FROM Oee.ShiftSummary WHERE ShiftId = @A AND (InputFingerprint <> @fp OR @fp IS NULL));
EXEC test.Assert_RowCount @TestName = N'[Compute] stores rows with fingerprint = ufn_ShiftInputFingerprint', @ExpectedCount = 0, @ActualCount = @bad;
DECLARE @diff INT = (SELECT COUNT(*) FROM (
    SELECT LocationId, RowKind, AreaFamily, BaseMinutes, EffectiveUnplannedMinutes, Good, Scrap, FoundDownstreamScrap, IsActive FROM Oee.ShiftSummary WHERE ShiftId = @A
    EXCEPT
    SELECT LocationId, RowKind, AreaFamily, BaseMinutes, EffectiveUnplannedMinutes, Good, Scrap, FoundDownstreamScrap, IsActive FROM Oee.ufn_ShiftSummaryRows(@A)) x);
EXEC test.Assert_RowCount @TestName = N'[Compute] stored rows = computed rows', @ExpectedCount = 0, @ActualCount = @diff;

DELETE FROM @st;
INSERT INTO @st EXEC Oee.ShiftSummary_Compute @ShiftId = @A, @AppUserId = 1;
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ShiftSummary WHERE ShiftId = @A);
EXEC test.Assert_IsEqual @TestName = N'[Compute] second run replaces, row count unchanged', @Expected = @e, @Actual = @v;

DELETE FROM @st;
INSERT INTO @st EXEC Oee.ShiftSummary_Compute @ShiftId = @C, @AppUserId = 1;
SET @v = (SELECT CAST(Status AS NVARCHAR(1)) FROM @st) + N'/' + CAST((SELECT COUNT(*) FROM Oee.ShiftSummary WHERE ShiftId = @C) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Compute] open shift refused, nothing stored', @Expected = N'0/0', @Actual = @v;
GO

-- =============================================
-- Test 3: the input fingerprint
-- =============================================
DECLARE @A BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_A');
DECLARE @B BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SS_B');
DECLARE @fa0 VARBINARY(32) = (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@A));
DECLARE @fb0 VARBINARY(32) = (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@B));
DECLARE @c BIT;

UPDATE Oee.DowntimeEvent SET IsApproximate = 1, DurationMinutes = 45 WHERE Remarks = N'ZZ-DSH no reason';
SET @c = CASE WHEN (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@A)) <> @fa0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Fingerprint] changes when a DowntimeEvent DurationMinutes changes', @Condition = @c;
SET @c = CASE WHEN (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@B)) = @fb0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Fingerprint] unchanged by an edit to another shift', @Condition = @c;
UPDATE Oee.DowntimeEvent SET IsApproximate = 0, DurationMinutes = NULL WHERE Remarks = N'ZZ-DSH no reason';
SET @c = CASE WHEN (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@A)) = @fa0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Fingerprint] deterministic: undoing the edit restores it', @Condition = @c;
GO

-- =============================================
-- Test 4: RecomputeRange
-- =============================================
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_SS_Day');
DECLARE @From DATETIME2(3) = '2030-03-04T00:00:00', @To DATETIME2(3) = '2030-03-07T00:00:00';
DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500), ShiftsComputed INT);
INSERT INTO @rr EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = @From, @ToUtc = @To, @AppUserId = 1;
DECLARE @v NVARCHAR(50) = (SELECT CAST(Status AS NVARCHAR(1)) + N'/' + CAST(ShiftsComputed AS NVARCHAR(10)) FROM @rr);
DECLARE @stored NVARCHAR(10) = (SELECT CAST(COUNT(DISTINCT ss.ShiftId) AS NVARCHAR(10)) FROM Oee.ShiftSummary ss
    INNER JOIN Oee.Shift s ON s.Id = ss.ShiftId WHERE s.Remarks IN (N'TEST_SS_A', N'TEST_SS_B'));
SET @v = @v + N'/' + @stored;
EXEC test.Assert_IsEqual @TestName = N'[Range] computes every ended shift in range, skips the open one', @Expected = N'1/2/2', @Actual = @v;
GO

-- ---- cleanup ----
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name LIKE N'TEST_SS_%');
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
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SS_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SS_%';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
