-- =============================================
-- File:         0117_Oee_Dashboard/010_ufn_ShiftAvailability.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  Oee.ufn_ShiftAvailability -- the availability calculation as a
--               table-valued function (OEE dashboard spec
--               docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--               sec 6.1). The dashboard procs read it per shift, and a proc
--               cannot INSERT-EXEC Oee.Shift_GetAvailability inside a test that
--               is itself an INSERT-EXEC, so the calculation has to live in a
--               function. Oee.Shift_GetAvailability v3.0 becomes a SELECT from it.
--
--               Same worked example as 0090_Oee_EnabledLocations/030: an 8-hour
--               shift, a 30-minute planned lunch on the line, 5 unplanned
--               minutes on Machining, 40 on Assembly A.
--                 Machining   445/450 = 0.9889
--                 Assembly A  410/450 = 0.9111
--                 Line        mean    = 0.9667
--               Plus parity: the function and the proc return identical rows.
--
--               Fixture times are mixed-basis ON PURPOSE (Oee.Shift.ActualStart
--               is LOCAL, Oee.DowntimeEvent.StartedAt is UTC), as in 0090/030.
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

-- ---- shift fixture: 06:00-14:00 on 2026-09-21 ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_UFN_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_UFN_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_UFN_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-21T06:00:00', '2026-09-21T14:00:00', N'TEST_UFN shift');
GO

DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_UFN_Day');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 (@L, @Lunch, @Shift,
  CAST(CAST('2026-09-21T11:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-21T11:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_UFN_lunch'),
 (@MI, NULL, @Shift,
  CAST(CAST('2026-09-21T08:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-21T08:05:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_UFN_mi'),
 (@A, NULL, @Shift,
  CAST(CAST('2026-09-21T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-21T09:40:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_UFN_a');
GO

-- =============================================
-- Test 1: the worked example, read straight from the function
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_UFN_Day');

DECLARE @mi NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@Shift) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[ufn] Machining 445/450 = 0.9889', @Expected = N'0.9889', @Actual = @mi;

DECLARE @a NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@Shift) WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[ufn] Assembly A 410/450 = 0.9111', @Expected = N'0.9111', @Actual = @a;

DECLARE @l NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@Shift) WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[ufn] Line mean 0.9667', @Expected = N'0.9667', @Actual = @l;

DECLARE @base NVARCHAR(10) = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM Oee.ufn_ShiftAvailability(@Shift) WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[ufn] planned lunch shrinks the base to 450', @Expected = N'450', @Actual = @base;

DECLARE @none INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftAvailability(-1));
EXEC test.Assert_RowCount @TestName = N'[ufn] unknown shift -> no rows', @ExpectedCount = 0, @ActualCount = @none;
GO

-- =============================================
-- Test 2: parity -- the proc and the function return identical rows
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_UFN_Day');
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
EXEC test.Assert_RowCount @TestName = N'[ufn] row count = proc row count', @ExpectedCount = @pc, @ActualCount = @fc;

DECLARE @diff INT = (SELECT COUNT(*) FROM (SELECT * FROM @p EXCEPT SELECT * FROM @f) x)
                  + (SELECT COUNT(*) FROM (SELECT * FROM @f EXCEPT SELECT * FROM @p) y);
EXEC test.Assert_RowCount @TestName = N'[ufn] EXCEPT proc result is empty, both directions', @ExpectedCount = 0, @ActualCount = @diff;
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
