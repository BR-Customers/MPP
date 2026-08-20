-- =============================================
-- File: 0059_Oee_ShiftOverride/030_availability.sql
-- Oee.Shift_GetAvailability: the override-aware planned-time denominator, and
-- the overlap-based downtime numerator.
--
-- Fixture times are mixed-basis ON PURPOSE, because the system is:
--   Oee.Shift.ActualStart / Oee.ShiftSchedule.StartTime  -> LOCAL Eastern (OI-38)
--   Oee.DowntimeEvent.StartedAt                          -> UTC
-- The proc converts the local window to UTC to compare. Downtime instants below
-- are therefore written as UTC via AT TIME ZONE from the local wall clock we
-- actually mean, so the tests stay correct on either side of a DST change.
--
-- EXEC parameters are literals or @variables only (project convention), so
-- every asserted value is hoisted into a local first.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0059_Oee_ShiftOverride/030_availability.sql';
GO

-- ---- fixture ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_AV_%';
DELETE FROM Oee.ShiftOverride
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_AV_%');
DELETE FROM Oee.Shift
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_AV_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_AV_%';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_AV_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO

-- Runtime shift instance. ActualStart is LOCAL -- the boundary engine's basis.
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-14T06:00:00', '2026-09-14T14:00:00', N'TEST_AV shift');
GO

-- =============================================
-- Test 1: no downtime -> planned 480, availability 1.0000. The business date
-- comes straight off ActualStart with NO timezone conversion -- converting it
-- is the live bug this proc deliberately avoids.
-- =============================================
DECLARE @Sched1 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
DECLARE @Shift1 BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @Sched1);
DECLARE @EqA    BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

DECLARE @a1 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a1 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift1, @LocationId = @EqA;

DECLARE @p1 NVARCHAR(10) = (SELECT CAST(PlannedMinutes AS NVARCHAR(10)) FROM @a1);
DECLARE @av1 NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @a1);
DECLARE @bd1 NVARCHAR(10) = (SELECT CONVERT(NVARCHAR(10), BusinessDate, 23) FROM @a1);
DECLARE @sl1 NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), StartLocal, 121) FROM @a1);
EXEC test.Assert_IsEqual @TestName = N'[AV.base] planned minutes from the schedule = 480',
     @Expected = N'480', @Actual = @p1;
EXEC test.Assert_IsEqual @TestName = N'[AV.base] no downtime -> availability 1.0000',
     @Expected = N'1.0000', @Actual = @av1;
EXEC test.Assert_IsEqual @TestName = N'[AV.base] business date taken from ActualStart WITHOUT conversion',
     @Expected = N'2026-09-14', @Actual = @bd1;
EXEC test.Assert_IsEqual @TestName = N'[AV.base] StartLocal is the local 06:00, NOT a UTC-shifted 02:00',
     @Expected = N'2026-09-14 06:00:00.000', @Actual = @sl1;
GO

-- =============================================
-- Test 2: 60 minutes of downtime inside the window -> 420/480 = 0.8750.
-- =============================================
DECLARE @Sched2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
DECLARE @Shift2 BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @Sched2);
DECLARE @EqA2   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @SrcId  BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

-- 09:00-10:00 LOCAL, stored as UTC (the column's real basis).
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES (@EqA2, NULL, @Shift2,
        CAST(CAST('2026-09-14T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        CAST(CAST('2026-09-14T10:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        @SrcId, N'TEST_AV_inside');

DECLARE @a2 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a2 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift2, @LocationId = @EqA2;

DECLARE @dm2 NVARCHAR(10) = (SELECT CAST(DowntimeMinutes AS NVARCHAR(10)) FROM @a2);
DECLARE @rm2 NVARCHAR(10) = (SELECT CAST(RunMinutes AS NVARCHAR(10)) FROM @a2);
DECLARE @av2 NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @a2);
EXEC test.Assert_IsEqual @TestName = N'[AV.downtime] 60 downtime minutes counted',
     @Expected = N'60', @Actual = @dm2;
EXEC test.Assert_IsEqual @TestName = N'[AV.downtime] run minutes 420',
     @Expected = N'420', @Actual = @rm2;
EXEC test.Assert_IsEqual @TestName = N'[AV.downtime] availability 0.8750',
     @Expected = N'0.8750', @Actual = @av2;
GO

-- =============================================
-- Test 3: downtime OUTSIDE the window is not counted, and downtime that
-- STRADDLES the end boundary is CLIPPED to the window.
--   16:00-17:00 local -> entirely after the 14:00 end -> 0 minutes.
--   13:30-14:30 local -> 30 minutes inside.
-- =============================================
DECLARE @Sched3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
DECLARE @Shift3 BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @Sched3);
DECLARE @EqA3   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB3   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA3 ORDER BY LocationId);
DECLARE @SrcId3 BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES (@EqB3, NULL, @Shift3,
        CAST(CAST('2026-09-14T16:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        CAST(CAST('2026-09-14T17:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        @SrcId3, N'TEST_AV_outside'),
       (@EqB3, NULL, @Shift3,
        CAST(CAST('2026-09-14T13:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        CAST(CAST('2026-09-14T14:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        @SrcId3, N'TEST_AV_straddle');

DECLARE @a3 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a3 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift3, @LocationId = @EqB3;

DECLARE @dm3 NVARCHAR(10) = (SELECT CAST(DowntimeMinutes AS NVARCHAR(10)) FROM @a3);
DECLARE @ec3 NVARCHAR(10) = (SELECT CAST(DowntimeEventCount AS NVARCHAR(10)) FROM @a3);
EXEC test.Assert_IsEqual @TestName = N'[AV.clip] straddling event clipped to 30 min, outside event ignored',
     @Expected = N'30', @Actual = @dm3;
EXEC test.Assert_IsEqual @TestName = N'[AV.clip] only the overlapping event is counted',
     @Expected = N'1', @Actual = @ec3;
GO

-- =============================================
-- Test 4: THE POINT OF THE FEATURE. An override extends this press to 18:00
-- (720 min), so the denominator AND the numerator both grow. Two effects, both
-- asserted:
--   (a) the 16:00-17:00 event that fell entirely OUTSIDE the global window is
--       now INSIDE the extended one            -> +60 min
--   (b) the 13:30-14:30 straddler is no longer clipped at the 14:00 boundary;
--       it now sits wholly inside, so it counts 60 rather than 30
--   planned 720, downtime = 60 + 60 = 120, run 600.
-- Bucketing by de.ShiftId instead of by time overlap would have grown only the
-- denominator and inflated availability; this test is what pins that down.
-- =============================================
DECLARE @Sched4 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
DECLARE @Shift4 BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @Sched4);
DECLARE @EqA4   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB4   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA4 ORDER BY LocationId);

DECLARE @c4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c4 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqB4, @ShiftScheduleId = @Sched4, @BusinessDate = '2026-09-14',
    @StartTime = '06:00:00', @EndTime = '18:00:00', @Reason = N'Overtime', @AppUserId = 1;
DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c4);
EXEC test.Assert_IsEqual @TestName = N'[AV.override] override created',
     @Expected = N'1', @Actual = @s4;

DECLARE @a4 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a4 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift4, @LocationId = @EqB4;

DECLARE @p4 NVARCHAR(10) = (SELECT CAST(PlannedMinutes AS NVARCHAR(10)) FROM @a4);
DECLARE @ov4 NVARCHAR(10) = (SELECT CAST(IsOverridden AS NVARCHAR(1)) FROM @a4);
DECLARE @dm4 NVARCHAR(10) = (SELECT CAST(DowntimeMinutes AS NVARCHAR(10)) FROM @a4);
DECLARE @rm4 NVARCHAR(10) = (SELECT CAST(RunMinutes AS NVARCHAR(10)) FROM @a4);
EXEC test.Assert_IsEqual @TestName = N'[AV.override] planned minutes follow the override (720)',
     @Expected = N'720', @Actual = @p4;
EXEC test.Assert_IsEqual @TestName = N'[AV.override] IsOverridden flagged on the availability row',
     @Expected = N'1', @Actual = @ov4;
EXEC test.Assert_IsEqual @TestName = N'[AV.override] downtime in the EXTENSION is now counted (120)',
     @Expected = N'120', @Actual = @dm4;
EXEC test.Assert_IsEqual @TestName = N'[AV.override] run minutes 600',
     @Expected = N'600', @Actual = @rm4;

-- The neighbouring press keeps the global 480 denominator on the same shift.
DECLARE @a4b TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a4b EXEC Oee.Shift_GetAvailability @ShiftId = @Shift4, @LocationId = @EqA4;
DECLARE @p4b NVARCHAR(10) = (SELECT CAST(PlannedMinutes AS NVARCHAR(10)) FROM @a4b);
EXEC test.Assert_IsEqual @TestName = N'[AV.override] a DIFFERENT press keeps planned 480 on the same shift',
     @Expected = N'480', @Actual = @p4b;
GO

-- =============================================
-- Test 5: a VOIDED downtime event does not count.
-- =============================================
DECLARE @Sched5 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
DECLARE @Shift5 BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @Sched5);
DECLARE @EqA5   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

UPDATE Oee.DowntimeEvent
SET VoidedAt = SYSUTCDATETIME(), VoidedByUserId = 1, VoidReason = N'TEST_AV void'
WHERE Remarks = N'TEST_AV_inside';

DECLARE @a5 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a5 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift5, @LocationId = @EqA5;
DECLARE @dm5 NVARCHAR(10) = (SELECT CAST(DowntimeMinutes AS NVARCHAR(10)) FROM @a5);
EXEC test.Assert_IsEqual @TestName = N'[AV.void] voided downtime excluded',
     @Expected = N'0', @Actual = @dm5;
GO

-- =============================================
-- Test 6: @LocationId NULL returns one row per piece of equipment; an unknown
-- shift returns an empty result set (no invented 404).
-- =============================================
DECLARE @Sched6 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AV_Day');
DECLARE @Shift6 BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @Sched6);

DECLARE @a6 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a6 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift6;

DECLARE @eqCnt  NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.ufn_ResolveOeeEquipment()) AS NVARCHAR(10));
DECLARE @rowCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM @a6) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AV.all] NULL location returns one row per equipment',
     @Expected = @eqCnt, @Actual = @rowCnt;

DECLARE @ovCnt INT = (SELECT COUNT(*) FROM @a6 WHERE IsOverridden = 1);
EXEC test.Assert_RowCount @TestName = N'[AV.all] exactly one overridden row in the set',
     @ExpectedCount = 1, @ActualCount = @ovCnt;

DECLARE @a6b TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
INSERT INTO @a6b EXEC Oee.Shift_GetAvailability @ShiftId = 99999999;
DECLARE @unkCnt INT = (SELECT COUNT(*) FROM @a6b);
EXEC test.Assert_RowCount @TestName = N'[AV.unknown] unknown shift -> empty result set',
     @ExpectedCount = 0, @ActualCount = @unkCnt;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
