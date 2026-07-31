-- =============================================
-- File: 0046_Shift_Reconcile/010_reconcile_core.sql
-- Core reconcile behaviors: open-from-empty, idempotent, snap ragged start.
-- Fixture: TEST_R_First/Second/Third (see plan). Local-time; explicit @NowLocal.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0046_Shift_Reconcile/010_reconcile_core.sql';
GO

-- ---- fixture: clean + (re)create the three TEST_R_ schedules ----
DELETE FROM Oee.Shift
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';

-- Isolate the test week from any other active schedule that could resolve as
-- "active" for a 06-08..06-14 @NowLocal. Temp-deprecate overlappers; the test
-- restores none (Run-Tests targets the throwaway MPP_MES_Test DB).
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME()
WHERE DeprecatedAt IS NULL AND Name NOT LIKE N'TEST_R_%';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_R_First',  N'First 07-15 Mon-Fri',  '07:00:00', '15:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Second', N'Second 15-23 Mon-Fri', '15:00:00', '23:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Third',  N'Third 23-07 Tue-Sat',  '23:00:00', '07:00:00', 62, '2020-01-01', 1);
GO

-- =============================================
-- Test 1: open-from-empty. Wed 06-10 10:00 -> First active, opens at 07:00.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r1 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;

DECLARE @FirstId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @openStart NVARCHAR(30) = (
    SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift
    WHERE ShiftScheduleId = @FirstId AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.open] First opened at scheduled 07:00',
     @Expected = N'2026-06-10 07:00:00.000', @Actual = @openStart;

DECLARE @openCnt NVARCHAR(10) = CAST(
    (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL
        AND ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.open] exactly one open shift',
     @Expected = N'1', @Actual = @openCnt;
GO

-- =============================================
-- Test 2: idempotent. Re-run at the same @Now -> no-op, no duplicate.
-- =============================================
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r2 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;
DECLARE @noop NVARCHAR(10) = (SELECT CASE WHEN ShiftsClosed = 0 AND ShiftsBackfilled = 0
    AND ShiftOpened IS NULL THEN N'1' ELSE N'0' END FROM @r2);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.idem] second run is a no-op', @Expected = N'1', @Actual = @noop;
DECLARE @rowCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift
    WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.idem] still exactly one row', @Expected = N'1', @Actual = @rowCnt;
GO

-- =============================================
-- Test 3: snap a ragged open start (07:03 -> 07:00), no new rows.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @Fid BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@Fid, '2026-06-10T07:03:11', NULL);
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r3 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;
DECLARE @snapped NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift
    WHERE ShiftScheduleId = @Fid AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.snap] ragged start snapped to 07:00',
     @Expected = N'2026-06-10 07:00:00.000', @Actual = @snapped;
DECLARE @snapCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift
    WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.snap] no new rows created', @Expected = N'1', @Actual = @snapCnt;
GO

-- =============================================
-- Test 4: cross-day SAME-schedule stale open. Open First shift is left over
-- from Monday (2026-06-08 07:00). Reconcile at Tuesday 2026-06-09 08:00 ->
-- active instance is ALSO First, but Tuesday's 07:00 instance, not Monday's.
-- Must close Monday's First at its scheduled end (15:00 Mon), backfill the
-- missed Second (Mon 15-23), and open a fresh First at Tue 07:00 -- NOT
-- relabel Monday's row to Tuesday's start.
-- NOTE: TEST_R_Third is bitmask 62 = Tue-Sat only (Monday's bit, 1, is not
-- set) -- it does not fire Monday night, so only Second backfills in this
-- gap (ShiftsBackfilled = 1), not 2. Verified against the fixture bitmask,
-- not assumed.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @Fid4 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@Fid4, '2026-06-08T07:00:00', NULL);
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r4 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-09T08:00:00', @AppUserId = 1;

DECLARE @mondayEnd NVARCHAR(30) = (
    SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift
    WHERE ShiftScheduleId = @Fid4 AND ActualStart = '2026-06-08T07:00:00');
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.crossday] Monday First closed at scheduled 15:00',
     @Expected = N'2026-06-08 15:00:00.000', @Actual = @mondayEnd;

DECLARE @tuesOpenStart NVARCHAR(30) = (
    SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift
    WHERE ShiftScheduleId = @Fid4 AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.crossday] new open First at Tuesday 07:00',
     @Expected = N'2026-06-09 07:00:00.000', @Actual = @tuesOpenStart;

DECLARE @bfCount NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @r4);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.crossday] one shift backfilled (Second; Third is Tue-Sat only)',
     @Expected = N'1', @Actual = @bfCount;

DECLARE @openCnt4 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift
    WHERE ActualEnd IS NULL AND ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.crossday] exactly one open shift remains',
     @Expected = N'1', @Actual = @openCnt4;
GO

-- ---- cleanup ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
