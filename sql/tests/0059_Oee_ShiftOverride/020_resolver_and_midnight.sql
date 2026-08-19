-- =============================================
-- File: 0059_Oee_ShiftOverride/020_resolver_and_midnight.sql
-- Oee.ufn_ShiftWindowForLocation: the fallback rule, and the midnight-crossing
-- boundary math.
--
-- All times are LOCAL (Eastern) wall clock -- the shift subsystem's basis
-- (OI-38). These tests assert on the naive local values DELIBERATELY: any
-- future UTC migration of the shift subsystem MUST change them, which is the
-- point of pinning them here.
--
-- EXEC parameters are literals or @variables only (project convention), so
-- every asserted value is hoisted into a local first.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0059_Oee_ShiftOverride/020_resolver_and_midnight.sql';
GO

-- ---- fixture ----
DELETE FROM Oee.ShiftOverride
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SW_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SW_%';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_SW_Day',   N'Day 06-14',   '06:00:00', '14:00:00', 31, '2020-01-01', 1),
       (N'TEST_SW_Night', N'Night 22-06', '22:00:00', '06:00:00', 31, '2020-01-01', 1);
GO

-- =============================================
-- Test 1: NO override -> the global schedule window (the fallback half of the
-- rule). Same-day shift: 2026-09-14 06:00 -> 14:00, 480 minutes.
-- =============================================
DECLARE @Day BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Day');
DECLARE @Eq  BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                       WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

DECLARE @st1  NVARCHAR(30), @en1 NVARCHAR(30), @du1 NVARCHAR(10), @ov1 NVARCHAR(10);
SELECT @st1 = CONVERT(NVARCHAR(30), StartLocal, 121),
       @en1 = CONVERT(NVARCHAR(30), EndLocal, 121),
       @du1 = CAST(DurationMinutes AS NVARCHAR(10)),
       @ov1 = CAST(IsOverridden AS NVARCHAR(1))
FROM Oee.ufn_ShiftWindowForLocation(@Eq, @Day, '2026-09-14');

EXEC test.Assert_IsEqual @TestName = N'[SW.fallback] no override -> schedule StartLocal',
     @Expected = N'2026-09-14 06:00:00.000', @Actual = @st1;
EXEC test.Assert_IsEqual @TestName = N'[SW.fallback] no override -> schedule EndLocal',
     @Expected = N'2026-09-14 14:00:00.000', @Actual = @en1;
EXEC test.Assert_IsEqual @TestName = N'[SW.fallback] duration 480 min',
     @Expected = N'480', @Actual = @du1;
EXEC test.Assert_IsEqual @TestName = N'[SW.fallback] IsOverridden = 0',
     @Expected = N'0', @Actual = @ov1;
GO

-- =============================================
-- Test 2: MIDNIGHT CROSSING with no override. Night 22:00-06:00 anchored on
-- 2026-09-14 must END on 2026-09-15, not 2026-09-14. 480 minutes, not negative.
-- =============================================
DECLARE @Night BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Night');
DECLARE @Eq2   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                         WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

DECLARE @st2 NVARCHAR(30), @en2 NVARCHAR(30), @du2 NVARCHAR(10);
SELECT @st2 = CONVERT(NVARCHAR(30), StartLocal, 121),
       @en2 = CONVERT(NVARCHAR(30), EndLocal, 121),
       @du2 = CAST(DurationMinutes AS NVARCHAR(10))
FROM Oee.ufn_ShiftWindowForLocation(@Eq2, @Night, '2026-09-14');

EXEC test.Assert_IsEqual @TestName = N'[SW.midnight] night StartLocal on the anchor date',
     @Expected = N'2026-09-14 22:00:00.000', @Actual = @st2;
EXEC test.Assert_IsEqual @TestName = N'[SW.midnight] night EndLocal rolls to the NEXT day',
     @Expected = N'2026-09-15 06:00:00.000', @Actual = @en2;
EXEC test.Assert_IsEqual @TestName = N'[SW.midnight] night duration 480 min, not negative',
     @Expected = N'480', @Actual = @du2;
GO

-- =============================================
-- Test 3: OVERRIDE WINS for the equipment it names, on the day it names.
-- Extend the Day shift on ONE press to 06:00-17:00 (660 min).
-- =============================================
DECLARE @Day3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Day');
DECLARE @EqA  BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB  BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA ORDER BY LocationId);

DECLARE @c3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c3 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA, @ShiftScheduleId = @Day3, @BusinessDate = '2026-09-14',
    @StartTime = '06:00:00', @EndTime = '17:00:00', @Reason = N'Extended', @AppUserId = 1;
DECLARE @s3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c3);
EXEC test.Assert_IsEqual @TestName = N'[SW.override] fixture override created',
     @Expected = N'1', @Actual = @s3;

DECLARE @duA NVARCHAR(10), @ovA NVARCHAR(10), @idA NVARCHAR(20);
SELECT @duA = CAST(DurationMinutes AS NVARCHAR(10)),
       @ovA = CAST(IsOverridden AS NVARCHAR(1)),
       @idA = CAST(ShiftOverrideId AS NVARCHAR(20))
FROM Oee.ufn_ShiftWindowForLocation(@EqA, @Day3, '2026-09-14');

EXEC test.Assert_IsEqual @TestName = N'[SW.override] overridden press gets the longer window',
     @Expected = N'660', @Actual = @duA;
EXEC test.Assert_IsEqual @TestName = N'[SW.override] IsOverridden = 1 for that press',
     @Expected = N'1', @Actual = @ovA;
EXEC test.Assert_IsNotNull @TestName = N'[SW.override] ShiftOverrideId reported', @Value = @idA;

-- The neighbouring press is untouched -- overrides are per-equipment.
DECLARE @duB NVARCHAR(10) = (SELECT CAST(DurationMinutes AS NVARCHAR(10))
                             FROM Oee.ufn_ShiftWindowForLocation(@EqB, @Day3, '2026-09-14'));
EXEC test.Assert_IsEqual @TestName = N'[SW.override] a DIFFERENT press keeps the global window',
     @Expected = N'480', @Actual = @duB;

-- The SAME press on a DIFFERENT day is untouched -- overrides are per-day.
DECLARE @duNext NVARCHAR(10) = (SELECT CAST(DurationMinutes AS NVARCHAR(10))
                                FROM Oee.ufn_ShiftWindowForLocation(@EqA, @Day3, '2026-09-15'));
EXEC test.Assert_IsEqual @TestName = N'[SW.override] the same press the NEXT day is unaffected',
     @Expected = N'480', @Actual = @duNext;

-- A NULL location can never match an override -- that is how a plant-wide
-- caller asks for the unmodified global window.
DECLARE @duNull NVARCHAR(10) = (SELECT CAST(DurationMinutes AS NVARCHAR(10))
                                FROM Oee.ufn_ShiftWindowForLocation(NULL, @Day3, '2026-09-14'));
EXEC test.Assert_IsEqual @TestName = N'[SW.override] NULL location = global window',
     @Expected = N'480', @Actual = @duNull;
GO

-- =============================================
-- Test 4: an override that EXTENDS A MIDNIGHT-CROSSING shift still lands on
-- BusinessDate + 1. Night 22:00-06:00 extended to 22:00-08:00 = 600 min.
-- =============================================
DECLARE @Night4 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Night');
DECLARE @EqA4   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

DECLARE @c4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c4 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA4, @ShiftScheduleId = @Night4, @BusinessDate = '2026-09-14',
    @StartTime = '22:00:00', @EndTime = '08:00:00', @Reason = N'Night overtime', @AppUserId = 1;
DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c4);
EXEC test.Assert_IsEqual @TestName = N'[SW.midnight] extended-night override created',
     @Expected = N'1', @Actual = @s4;

DECLARE @en4 NVARCHAR(30), @du4 NVARCHAR(10);
SELECT @en4 = CONVERT(NVARCHAR(30), EndLocal, 121),
       @du4 = CAST(DurationMinutes AS NVARCHAR(10))
FROM Oee.ufn_ShiftWindowForLocation(@EqA4, @Night4, '2026-09-14');

EXEC test.Assert_IsEqual @TestName = N'[SW.midnight] extended night EndLocal is next-day 08:00',
     @Expected = N'2026-09-15 08:00:00.000', @Actual = @en4;
EXEC test.Assert_IsEqual @TestName = N'[SW.midnight] extended night duration 600 min',
     @Expected = N'600', @Actual = @du4;
GO

-- =============================================
-- Test 5: an override that SHORTENS a midnight-crossing shift into a same-day
-- one (22:00 -> 23:30 stays same-day because End > Start).
-- =============================================
DECLARE @Night5 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Night');
DECLARE @EqA5   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB5   BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA5 ORDER BY LocationId);

DECLARE @c5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c5 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqB5, @ShiftScheduleId = @Night5, @BusinessDate = '2026-09-14',
    @StartTime = '22:00:00', @EndTime = '23:30:00', @Reason = N'Short run', @AppUserId = 1;
DECLARE @s5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c5);
EXEC test.Assert_IsEqual @TestName = N'[SW.shorten] shortening override created',
     @Expected = N'1', @Actual = @s5;

DECLARE @en5 NVARCHAR(30), @du5 NVARCHAR(10);
SELECT @en5 = CONVERT(NVARCHAR(30), EndLocal, 121),
       @du5 = CAST(DurationMinutes AS NVARCHAR(10))
FROM Oee.ufn_ShiftWindowForLocation(@EqB5, @Night5, '2026-09-14');

EXEC test.Assert_IsEqual @TestName = N'[SW.shorten] End > Start -> same-day EndLocal',
     @Expected = N'2026-09-14 23:30:00.000', @Actual = @en5;
EXEC test.Assert_IsEqual @TestName = N'[SW.shorten] shortened duration 90 min',
     @Expected = N'90', @Actual = @du5;
GO

-- =============================================
-- Test 6: an override on a day the schedule's DaysOfWeekBitmask EXCLUDES still
-- resolves -- the "Saturday overtime on one press" case. Both fixtures are
-- Mon-Fri (bitmask 31); 2026-09-19 is a Saturday.
-- =============================================
DECLARE @Day6 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Day');
DECLARE @EqA6 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

DECLARE @isoDow NVARCHAR(2) = CAST(((DATEPART(WEEKDAY, CAST('2026-09-19' AS DATE)) + @@DATEFIRST + 5) % 7 + 1) AS NVARCHAR(2));
EXEC test.Assert_IsEqual @TestName = N'[SW.satday] 2026-09-19 is a Saturday (fixture sanity)',
     @Expected = N'6', @Actual = @isoDow;

DECLARE @c6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c6 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA6, @ShiftScheduleId = @Day6, @BusinessDate = '2026-09-19',
    @StartTime = '06:00:00', @EndTime = '12:00:00', @Reason = N'Saturday overtime', @AppUserId = 1;
DECLARE @s6 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c6);
DECLARE @du6 NVARCHAR(10) = (SELECT CAST(DurationMinutes AS NVARCHAR(10))
                             FROM Oee.ufn_ShiftWindowForLocation(@EqA6, @Day6, '2026-09-19'));
EXEC test.Assert_IsEqual @TestName = N'[SW.satday] override accepted on an off-schedule day',
     @Expected = N'1', @Actual = @s6;
EXEC test.Assert_IsEqual @TestName = N'[SW.satday] resolves to the override window',
     @Expected = N'360', @Actual = @du6;
GO

-- =============================================
-- Test 7: a DEPRECATED override falls back to the global window.
-- =============================================
DECLARE @Day7 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SW_Day');
DECLARE @EqA7 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @Id7  BIGINT = (SELECT Id FROM Oee.ShiftOverride
                        WHERE LocationId = @EqA7 AND ShiftScheduleId = @Day7
                          AND BusinessDate = '2026-09-14' AND DeprecatedAt IS NULL);

DECLARE @d7 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @d7 EXEC Oee.ShiftOverride_Deprecate @Id = @Id7, @AppUserId = 1;

DECLARE @du7 NVARCHAR(10), @ov7 NVARCHAR(10);
SELECT @du7 = CAST(DurationMinutes AS NVARCHAR(10)),
       @ov7 = CAST(IsOverridden AS NVARCHAR(1))
FROM Oee.ufn_ShiftWindowForLocation(@EqA7, @Day7, '2026-09-14');

EXEC test.Assert_IsEqual @TestName = N'[SW.deprecated] falls back to the global window',
     @Expected = N'480', @Actual = @du7;
EXEC test.Assert_IsEqual @TestName = N'[SW.deprecated] IsOverridden back to 0',
     @Expected = N'0', @Actual = @ov7;
GO

-- =============================================
-- Test 8: an unknown / deprecated schedule yields NO row (not a phantom window).
-- =============================================
DECLARE @unkCnt INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftWindowForLocation(NULL, 99999999, '2026-09-14'));
EXEC test.Assert_RowCount @TestName = N'[SW.unknown] unknown schedule -> empty result',
     @ExpectedCount = 0, @ActualCount = @unkCnt;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
