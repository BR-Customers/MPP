-- =============================================
-- File:         0090_Oee_EnabledLocations/030_rollup_availability.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Oee.Shift_GetAvailability once a line is split into stations:
--                 * planned downtime SHRINKS the base (it no longer counts
--                   against availability, which is the 2026-09-16 fix);
--                 * downtime on the LINE counts against EVERY station under it;
--                 * the line reports the unweighted MEAN of its stations;
--                 * a line event overlapping a station event counts once;
--                 * planned overlapping unplanned counts as planned;
--                 * a child with a zero base is excluded from the mean;
--                 * roll-ups nest.
--
--               The worked example is the spec's: an 8-hour shift, a 30-minute
--               lunch on the line, 5 minutes on Machining, 40 on Assembly A.
--                 Machining   445/450 = 0.9889
--                 Assembly A  410/450 = 0.9111
--                 Assembly B  450/450 = 1.0000
--                 Line        mean    = 0.9667
--
--               Fixture times are mixed-basis ON PURPOSE (Oee.Shift.ActualStart
--               is LOCAL, Oee.DowntimeEvent.StartedAt is UTC) -- see
--               0059_Oee_ShiftOverride/030_availability.sql for the same
--               convention.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/030_rollup_availability.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- ---- reason fixture: a PLANNED (IsExcused = 1) LUNCH code ----
-- Migration 0026 seeds LUNCH only when a Site already exists at migration
-- time, which a fresh reset does not have, so a filtered run finds no LUNCH
-- and every "planned" event below would silently become unplanned. Re-seed
-- idempotently, exactly as 0026_PlantFloor_Downtime_Shift/020 does, and left
-- in place afterwards like theirs (other suites share it).
DECLARE @BreakTypeId BIGINT = (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break');
INSERT INTO Oee.DowntimeReasonCode (Code, Description, OperationCategoryId, DowntimeReasonTypeId, IsExcused, StandardDurationMinutes, CreatedByUserId)
SELECT N'LUNCH', N'Scheduled lunch', NULL, @BreakTypeId, 1, 30, 1
WHERE NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode rc WHERE rc.Code = N'LUNCH');
DECLARE @LunchExcused NVARCHAR(10) = (SELECT CAST(IsExcused AS NVARCHAR(10)) FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] fixture: LUNCH exists and is planned (IsExcused = 1)',
     @Expected = N'1', @Actual = @LunchExcused;
GO

-- ---- shift fixture: an 06:00-14:00 day shift on 2026-09-14 ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_RU_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-14T06:00:00', '2026-09-14T14:00:00', N'TEST_RU shift');
GO

-- ---- downtime fixture: lunch on the line, a Machining stop, an Assembly A jam ----
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 -- 11:00-11:30 LOCAL lunch, logged against the LINE -> planned, and it must
 -- reach all three stations.
 (@L, @Lunch, @Shift,
  CAST(CAST('2026-09-14T11:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T11:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RU_lunch'),
 -- 08:00-08:05 Machining stop, no reason -> unplanned.
 (@MI, NULL, @Shift,
  CAST(CAST('2026-09-14T08:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T08:05:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RU_mi'),
 -- 09:00-09:40 Assembly A jam -> unplanned.
 (@A, NULL, @Shift,
  CAST(CAST('2026-09-14T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T09:40:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RU_a');
GO

-- Result-set shape, declared once per test (23 columns).
-- =============================================
-- Test 1: the worked example -- per-station figures.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @av TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @miBase NVARCHAR(10) = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] planned lunch shrinks the base: 480 - 30 = 450',
     @Expected = N'450', @Actual = @miBase;

DECLARE @miPl NVARCHAR(10) = (SELECT CAST(PlannedDowntimeMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] the line lunch reaches Machining as planned downtime',
     @Expected = N'30', @Actual = @miPl;

DECLARE @miUn NVARCHAR(10) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Machining carries its own 5 unplanned minutes',
     @Expected = N'5', @Actual = @miUn;

DECLARE @miAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Machining availability 445/450 = 0.9889',
     @Expected = N'0.9889', @Actual = @miAv;

DECLARE @aAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Assembly A availability 410/450 = 0.9111',
     @Expected = N'0.9111', @Actual = @aAv;

DECLARE @bAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-B');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Assembly B, hit only by the lunch, is 1.0000',
     @Expected = N'1.0000', @Actual = @bAv;

DECLARE @bUn NVARCHAR(10) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-B');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a station takes no unplanned time from its siblings',
     @Expected = N'0', @Actual = @bUn;
GO

-- =============================================
-- Test 2: the line is the mean of its three stations, and is marked a roll-up.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @av2 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av2 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @lAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] the line is the mean of 0.9889 / 0.9111 / 1.0000 = 0.9667',
     @Expected = N'0.9667', @Actual = @lAv;

DECLARE @lRu NVARCHAR(10) = (SELECT CAST(IsRollup AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] the line row is flagged IsRollup',
     @Expected = N'1', @Actual = @lRu;

DECLARE @aRu NVARCHAR(10) = (SELECT CAST(IsRollup AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a station is not a roll-up',
     @Expected = N'0', @Actual = @aRu;

DECLARE @aPar NVARCHAR(50) = (SELECT p.Code FROM @av2 a INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
                              WHERE a.LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a station reports its line as ParentLocationId',
     @Expected = N'ZZ-OEE-L', @Actual = @aPar;

-- An unsplit line still reports its own figure, unchanged by any of this.
DECLARE @pAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-P');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] an unsplit line with no downtime is still 1.0000',
     @Expected = N'1.0000', @Actual = @pAv;
GO

-- =============================================
-- Test 3: a line event overlapping a station event counts ONCE, and planned
-- wins over unplanned on the minutes they share.
--   Assembly B: 10:00-10:30 unplanned (station) while the line is stopped
--   10:15-10:45 planned. Union = 10:00-10:45 = 45 minutes, of which the
--   30 planned minutes are planned and the remaining 15 unplanned.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @L2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @B2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-B');
DECLARE @Src2 BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch2 BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 (@B2, NULL, @Shift,
  CAST(CAST('2026-09-14T10:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T10:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src2, N'TEST_RU_overlap_station'),
 (@L2, @Lunch2, @Shift,
  CAST(CAST('2026-09-14T10:15:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T10:45:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src2, N'TEST_RU_overlap_line');

DECLARE @av3 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av3 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift, @LocationId = @B2;

DECLARE @bTot NVARCHAR(10) = (SELECT CAST(DowntimeMinutes AS NVARCHAR(10)) FROM @av3);
EXEC test.Assert_IsEqual @TestName = N'[Rollup] overlapping line + station events are merged (30 lunch + 45 union = 75, not 90)',
     @Expected = N'75', @Actual = @bTot;

DECLARE @bPl NVARCHAR(10) = (SELECT CAST(PlannedDowntimeMinutes AS NVARCHAR(10)) FROM @av3);
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a minute covered by a planned event counts as planned (30 + 30)',
     @Expected = N'60', @Actual = @bPl;

DECLARE @bUn3 NVARCHAR(10) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM @av3);
EXEC test.Assert_IsEqual @TestName = N'[Rollup] only the 15 uncovered minutes stay unplanned',
     @Expected = N'15', @Actual = @bUn3;
GO

-- =============================================
-- Test 4: @LocationId filters to one row, and an unknown shift is empty.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @L4 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @av4 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av4 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift, @LocationId = @L4;
DECLARE @c4 INT = (SELECT COUNT(*) FROM @av4);
EXEC test.Assert_RowCount @TestName = N'[Rollup] @LocationId returns exactly one row -- a roll-up still resolves its children internally',
     @ExpectedCount = 1, @ActualCount = @c4;
DECLARE @l4Av NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av4);
EXEC test.Assert_IsNotNull @TestName = N'[Rollup] and it still carries the mean', @Value = @l4Av;

DELETE FROM @av4;
INSERT INTO @av4 EXEC Oee.Shift_GetAvailability @ShiftId = -1;
DECLARE @c4b INT = (SELECT COUNT(*) FROM @av4);
EXEC test.Assert_RowCount @TestName = N'[Rollup] unknown shift -> empty result set',
     @ExpectedCount = 0, @ActualCount = @c4b;
GO

-- ---- cleanup ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_RU_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day';
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
