-- =============================================
-- File:         0117_Oee_Dashboard/010_ufn_ShiftAvailability.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  Oee.ufn_ShiftAvailability v2.0 -- availability from entered
--               DURATIONS, summed (OEE dashboard spec v0.3.1 sec 6.1, D17).
--               Entries count against the shift they were entered for
--               (DowntimeEvent.ShiftId), not by clock overlap: MPP's end-of-shift
--               entries all sit at the shift start, so a clock merge would count
--               two 30-minute entries as 30. Worked examples, 480-minute shifts:
--                 S1  the 0090/030 example (lunch on the line, 5 on MI, 40 on A)
--                     MI 445/450 = 0.9889, A 410/450 = 0.9111, line mean 0.9667
--                 S2  MI two 30-min entries at shift start -> 420/480 = 0.8750
--                     A  30 planned + 45 unplanned        -> 405/450 = 0.9000
--                     line mean (0.8750 + 0.9000 + 1)/3   = 0.9250
--                 S3  a 20-min line entry counts on every station -> 0.9583;
--                     a voided 100-min entry on MI is ignored; an entry whose
--                     ShiftId is S4 but whose clock time is inside S3 is ignored
--                 S4  MI 600 unplanned, capped at the base -> 0.0000;
--                     A 480 planned -> base 0 -> NULL
--                 S5  a real-time entry with no EndedAt in a closed shift runs to
--                     the window end (60 min) -> 0.8750
--               Plus parity: Oee.Shift_GetAvailability returns the same rows.
--               Fixture times are mixed-basis ON PURPOSE (Oee.Shift.ActualStart is
--               LOCAL, Oee.DowntimeEvent.StartedAt is UTC), as in 0090/030.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/010_ufn_ShiftAvailability.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- ---- planned LUNCH code (re-seeded idempotently, as 0090/030 does) ----
DECLARE @BreakTypeId BIGINT = (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break');
INSERT INTO Oee.DowntimeReasonCode (Code, Description, OperationCategoryId, DowntimeReasonTypeId, IsExcused, StandardDurationMinutes, CreatedByUserId)
SELECT N'LUNCH', N'Scheduled lunch', NULL, @BreakTypeId, 1, 30, 1
WHERE NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode rc WHERE rc.Code = N'LUNCH');
GO

-- ---- shifts: 06:00-14:00 on 2026-09-21 .. 2026-09-25 (S1..S5) ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_UFN_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_UFN_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-21T06:00:00', '2026-09-21T14:00:00', N'TEST_UFN S1'),
       (@Sched, '2026-09-22T06:00:00', '2026-09-22T14:00:00', N'TEST_UFN S2'),
       (@Sched, '2026-09-23T06:00:00', '2026-09-23T14:00:00', N'TEST_UFN S3'),
       (@Sched, '2026-09-24T06:00:00', '2026-09-24T14:00:00', N'TEST_UFN S4'),
       (@Sched, '2026-09-25T06:00:00', '2026-09-25T14:00:00', N'TEST_UFN S5');
GO

DECLARE @S1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S1');
DECLARE @S2 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S2');
DECLARE @S3 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S3');
DECLARE @S4 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S4');
DECLARE @S5 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S5');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

-- local -> UTC helper values
DECLARE @tz NVARCHAR(40) = N'Eastern Standard Time';

-- S1: the 0090/030 worked example (real start/end times)
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 (@L, @Lunch, @S1,
  CAST(CAST('2026-09-21T11:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-21T11:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_UFN_lunch'),
 (@MI, NULL, @S1,
  CAST(CAST('2026-09-21T08:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-21T08:05:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_UFN_mi'),
 (@A, NULL, @S1,
  CAST(CAST('2026-09-21T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-21T09:40:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_UFN_a');

-- S2: approximate end-of-shift entries, all anchored at the shift start (as
-- DowntimeEvent_RecordApproximate stores them: StartedAt = shift start,
-- EndedAt = start + duration, DurationMinutes authoritative).
DECLARE @S2Start DATETIME2(3) = CAST(CAST('2026-09-22T06:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
VALUES
 (@MI, NULL,   @S2, @S2Start, DATEADD(MINUTE, 30, @S2Start), @Src, N'TEST_UFN_s2_mi1', 1, 30),
 (@MI, NULL,   @S2, @S2Start, DATEADD(MINUTE, 30, @S2Start), @Src, N'TEST_UFN_s2_mi2', 1, 30),
 (@A,  @Lunch, @S2, @S2Start, DATEADD(MINUTE, 30, @S2Start), @Src, N'TEST_UFN_s2_al',  1, 30),
 (@A,  NULL,   @S2, @S2Start, DATEADD(MINUTE, 45, @S2Start), @Src, N'TEST_UFN_s2_au',  1, 45);

-- S3: a 20-minute line entry; a voided 100-minute MI entry; an MI entry
-- whose clock time is inside S3 but which was entered against S4.
DECLARE @S3At DATETIME2(3) = CAST(CAST('2026-09-23T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, VoidedAt)
VALUES
 (@L,  NULL, @S3, @S3At, DATEADD(MINUTE, 20, @S3At),  @Src, N'TEST_UFN_s3_line', NULL),
 (@MI, NULL, @S3, @S3At, DATEADD(MINUTE, 100, @S3At), @Src, N'TEST_UFN_s3_void', SYSUTCDATETIME()),
 (@MI, NULL, @S4, @S3At, DATEADD(MINUTE, 50, @S3At),  @Src, N'TEST_UFN_s3_other', NULL);

-- S4: 600 unplanned on MI (capped); a 480-minute planned entry on A (base 0).
DECLARE @S4Start DATETIME2(3) = CAST(CAST('2026-09-24T06:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
VALUES
 (@MI, NULL,   @S4, @S4Start, DATEADD(MINUTE, 600, @S4Start), @Src, N'TEST_UFN_s4_mi', 1, 600),
 (@A,  @Lunch, @S4, @S4Start, DATEADD(MINUTE, 480, @S4Start), @Src, N'TEST_UFN_s4_a',  1, 480);

-- S5: a real-time stop that was never closed, starting 60 minutes before the window end.
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES (@MI, NULL, @S5,
        CAST(CAST('2026-09-25T13:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        NULL, @Src, N'TEST_UFN_s5_open');
GO

-- =============================================
-- Worked examples
-- =============================================
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S1');
DECLARE @S2 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S2');
DECLARE @S3 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S3');
DECLARE @S4 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S4');
DECLARE @S5 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S5');
DECLARE @v NVARCHAR(40);

SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Avail] S1 Machining 445/450 = 0.9889', @Expected = N'0.9889', @Actual = @v;
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Avail] S1 Assembly A 410/450 = 0.9111', @Expected = N'0.9111', @Actual = @v;
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[Avail] S1 line mean 0.9667', @Expected = N'0.9667', @Actual = @v;
SET @v = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Avail] S1 planned lunch on the line shrinks a station base to 450', @Expected = N'450', @Actual = @v;

SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) + N'/' + CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S2) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Avail] two 30-min approximate entries at shift start -> 60 unplanned, 0.8750', @Expected = N'60/0.8750', @Actual = @v;
SET @v = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) + N'/' + CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S2) WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Avail] 30 planned + 45 unplanned -> base 450, 0.9000', @Expected = N'450/0.9000', @Actual = @v;
SET @v = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S2) WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[Avail] roll-up line = mean of stations (0.9250)', @Expected = N'0.9250', @Actual = @v;

SET @v = (SELECT CAST(MIN(Availability) AS NVARCHAR(10)) + N'/' + CAST(MAX(Availability) AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S3)
          WHERE LocationCode IN (N'ZZ-OEE-L-A', N'ZZ-OEE-L-B'));
EXEC test.Assert_IsEqual @TestName = N'[Avail] line entry 20 min counts on each station', @Expected = N'0.9583/0.9583', @Actual = @v;
SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S3) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Avail] voided entry and another shift''s entry (clock-inside) ignored', @Expected = N'20', @Actual = @v;

SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) + N'/' + CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S4) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Avail] unplanned 650 capped at base 480 -> 0.0000', @Expected = N'480/0.0000', @Actual = @v;
SET @v = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) + N'/' + ISNULL(CAST(Availability AS NVARCHAR(10)), N'NULL') FROM Oee.ufn_ShiftAvailability(@S4) WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Avail] Base 0 -> Availability NULL', @Expected = N'0/NULL', @Actual = @v;

SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) + N'/' + CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@S5) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Avail] open entry runs to window end', @Expected = N'60/0.8750', @Actual = @v;

DECLARE @none INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftAvailability(-1));
EXEC test.Assert_RowCount @TestName = N'[Avail] unknown shift -> no rows', @ExpectedCount = 0, @ActualCount = @none;
GO

-- =============================================
-- Parity -- the proc and the function return identical rows
-- =============================================
DECLARE @Shift BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_UFN S2');
DECLARE @p TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @p EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @f TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @f
SELECT ShiftId, ShiftScheduleId, ScheduleName, BusinessDate, LocationId, LocationCode, LocationName,
       StartLocal, EndLocal, PlannedMinutes, DowntimeMinutes, UnexcusedDowntimeMinutes, RunMinutes,
       Availability, DowntimeEventCount, IsOverridden, ShiftOverrideId, OverrideReason,
       PlannedDowntimeMinutes, UnplannedDowntimeMinutes, BaseMinutes, IsRollup, ParentLocationId
FROM Oee.ufn_ShiftAvailability(@Shift);

DECLARE @pc INT = (SELECT COUNT(*) FROM @p), @fc INT = (SELECT COUNT(*) FROM @f);
EXEC test.Assert_RowCount @TestName = N'[Avail] row count = proc row count', @ExpectedCount = @pc, @ActualCount = @fc;

DECLARE @diff INT = (SELECT COUNT(*) FROM (SELECT * FROM @p EXCEPT SELECT * FROM @f) x)
                  + (SELECT COUNT(*) FROM (SELECT * FROM @f EXCEPT SELECT * FROM @p) y);
EXEC test.Assert_RowCount @TestName = N'[Avail] EXCEPT proc result is empty, both directions', @ExpectedCount = 0, @ActualCount = @diff;
GO

-- ---- cleanup ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_UFN_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day';
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
