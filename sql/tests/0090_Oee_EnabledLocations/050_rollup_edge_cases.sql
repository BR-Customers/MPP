-- =============================================
-- File:         0090_Oee_EnabledLocations/050_rollup_edge_cases.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Two things the mean can get wrong:
--                 1. A child whose base is ZERO (planned downtime swallowed the
--                    whole window) has NO availability, and must be left OUT of
--                    the mean rather than dragging it to 0.
--                 2. Roll-ups NEST: a line under a line reports the mean of its
--                    own stations, and the outer line then averages that.
--               The nested shape is built here rather than in the shared
--               fixture because it is not how any real MPP line is modelled --
--               prod's one line-under-a-line (AO-OP) was a mis-typed terminal,
--               corrected 2026-09-17. The rule still has to hold.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/050_rollup_edge_cases.sql';
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
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] fixture: LUNCH exists and is planned (IsExcused = 1)',
     @Expected = N'1', @Actual = @LunchExcused;
GO

-- ---- an inner line under ZZ-OEE-L, with one station of its own ----
DECLARE @L       BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @LineDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionLine');
DECLARE @AsmDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'AssemblyStation');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled)
VALUES (@LineDef, @L, N'OEE Inner Line', N'ZZ-OEE-L-INNER', N'OEE test fixture', 5, 1);
DECLARE @Inner BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-INNER');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled)
VALUES (@AsmDef, @Inner, N'OEE Inner Station', N'ZZ-OEE-L-INNER-S', N'OEE test fixture', 1, 1);
GO

-- ---- shift + downtime fixture ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_RE_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-14T06:00:00', '2026-09-14T14:00:00', N'TEST_RE shift');
GO

-- Assembly A is planned-down for the ENTIRE 06:00-14:00 window -> base 0.
-- Machining takes a 48-minute unplanned stop -> 432/480 = 0.9000.
-- Assembly B and the inner branch run clean -> 1.0000.
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RE_Day');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 (@A, @Lunch, @Shift,
  CAST(CAST('2026-09-14T06:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T14:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RE_allplanned'),
 (@MI, NULL, @Shift,
  CAST(CAST('2026-09-14T08:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T08:48:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RE_mi');
GO

-- =============================================
-- Test 1: a zero-base child reports NULL and is excluded from the mean.
--   Machining 0.9000, Assembly B 1.0000, inner line 1.0000, Assembly A NULL
--   -> outer line = (0.9 + 1.0 + 1.0) / 3 = 0.9667
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RE_Day');
DECLARE @av TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @aBase NVARCHAR(10) = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] a wholly planned-down station has a zero base',
     @Expected = N'0', @Actual = @aBase;

DECLARE @aAv DECIMAL(5,4) = (SELECT Availability FROM @av WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsNull @TestName = N'[RollupEdge] and no availability at all', @Value = @aAv;

DECLARE @miAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] Machining 432/480 = 0.9000',
     @Expected = N'0.9000', @Actual = @miAv;

DECLARE @lAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the NULL child is left out of the mean: (0.9 + 1.0 + 1.0) / 3 = 0.9667',
     @Expected = N'0.9667', @Actual = @lAv;
GO

-- =============================================
-- Test 2: roll-ups nest -- the inner line is itself a mean, and reports the
-- outer line as its parent.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RE_Day');
DECLARE @av2 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av2 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @innerRu NVARCHAR(10) = (SELECT CAST(IsRollup AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L-INNER');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the inner line is itself a roll-up',
     @Expected = N'1', @Actual = @innerRu;

DECLARE @innerAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L-INNER');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the inner line reports its own station',
     @Expected = N'1.0000', @Actual = @innerAv;

DECLARE @innerPar NVARCHAR(50) = (SELECT p.Code FROM @av2 a INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
                                  WHERE a.LocationCode = N'ZZ-OEE-L-INNER');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] and hangs off the outer line',
     @Expected = N'ZZ-OEE-L', @Actual = @innerPar;

DECLARE @sPar NVARCHAR(50) = (SELECT p.Code FROM @av2 a INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
                              WHERE a.LocationCode = N'ZZ-OEE-L-INNER-S');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the inner station belongs to the INNER line, not the outer one',
     @Expected = N'ZZ-OEE-L-INNER', @Actual = @sPar;
GO

-- ---- cleanup ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_RE_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day';
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
