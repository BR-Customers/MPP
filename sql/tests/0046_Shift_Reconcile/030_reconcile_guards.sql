-- =============================================
-- File: 0046_Shift_Reconcile/030_reconcile_guards.sql
-- 7-day backfill cap, uncovered-gap (no open), first-ever run, B3 invariant.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0046_Shift_Reconcile/030_reconcile_guards.sql';
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME()
WHERE DeprecatedAt IS NULL AND Name NOT LIKE N'TEST_R_%';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_R_First',  N'First 07-15 Mon-Fri',  '07:00:00', '15:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Second', N'Second 15-23 Mon-Fri', '15:00:00', '23:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Third',  N'Third 23-07 Tue-Sat',  '23:00:00', '07:00:00', 62, '2020-01-01', 1);
GO
DECLARE @F BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');

-- =============================================
-- Test 1: 7-day cap. A closed shift ended 06-01 23:00 (9 days before now);
--   no open shift. now = Wed 06-10 10:00 -> First. Gap exceeds 7d -> NO backfill,
--   just open First 06-10 07:00.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F,@S,@T);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@S, '2026-06-01T15:00:00', '2026-06-01T23:00:00');
DECLARE @g1 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @g1 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @MaxBackfillDays = 7, @AppUserId = 1;

DECLARE @capBf NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @g1);
EXEC test.Assert_IsEqual @TestName = N'[Guard.cap] no backfill beyond 7 days', @Expected = N'0', @Actual = @capBf;
DECLARE @capOpen NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift WHERE ShiftScheduleId=@F AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Guard.cap] current First still opened at 07:00',
     @Expected = N'2026-06-10 07:00:00.000', @Actual = @capOpen;
GO

-- =============================================
-- Test 2: uncovered gap. Stale open Third from Sat 06-13 23:00; now = Sun 06-14
--   09:00 (no schedule covers it). Expect: Third closed at its sched end
--   06-14 07:00; NO open shift remains.
-- =============================================
DECLARE @F2 BIGINT=(SELECT Id FROM Oee.ShiftSchedule WHERE Name=N'TEST_R_First');
DECLARE @S2 BIGINT=(SELECT Id FROM Oee.ShiftSchedule WHERE Name=N'TEST_R_Second');
DECLARE @T2 BIGINT=(SELECT Id FROM Oee.ShiftSchedule WHERE Name=N'TEST_R_Third');
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F2,@S2,@T2);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@T2, '2026-06-13T23:00:00', NULL);
DECLARE @g2 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @g2 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-14T09:00:00', @AppUserId = 1;

DECLARE @gapEnd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift WHERE ShiftScheduleId=@T2);
EXEC test.Assert_IsEqual @TestName = N'[Guard.gap] stale Third closed at sched end 06-14 07:00',
     @Expected = N'2026-06-14 07:00:00.000', @Actual = @gapEnd;
DECLARE @gapOpen NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL AND ShiftScheduleId IN (@F2,@S2,@T2)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Guard.gap] no open shift in uncovered gap', @Expected = N'0', @Actual = @gapOpen;
GO

-- =============================================
-- Test 3: first-ever run. Empty table; now = Wed 06-10 10:00 -> opens First,
--   0 backfilled, 0 closed.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @g3 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @g3 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;
DECLARE @firstEver NVARCHAR(20) = (SELECT CASE WHEN ShiftsClosed=0 AND ShiftsBackfilled=0 AND ShiftOpened IS NOT NULL THEN N'1' ELSE N'0' END FROM @g3);
EXEC test.Assert_IsEqual @TestName = N'[Guard.first] first-ever opens current, no backfill/close', @Expected = N'1', @Actual = @firstEver;
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
