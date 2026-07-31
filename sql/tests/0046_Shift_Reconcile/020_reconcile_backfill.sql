-- =============================================
-- File: 0046_Shift_Reconcile/020_reconcile_backfill.sql
-- Close-at-scheduled-end, single boundary, and missed-boundary backfill
-- (incl. overnight Third). Local-time; explicit @NowLocal.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0046_Shift_Reconcile/020_reconcile_backfill.sql';
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
-- Test 1: single clean boundary. Open First (07:00); now = Wed 15:05 -> Second.
--   First closes at 15:00; Second opens at 15:00; 0 backfilled.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F,@S,@T);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@F, '2026-06-10T07:00:00', NULL);
DECLARE @b1 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @b1 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T15:05:00', @AppUserId = 1;

DECLARE @firstEnd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift WHERE ShiftScheduleId=@F);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.single] First closed at 15:00',
     @Expected = N'2026-06-10 15:00:00.000', @Actual = @firstEnd;
DECLARE @secStart NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift WHERE ShiftScheduleId=@S AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.single] Second opened at 15:00',
     @Expected = N'2026-06-10 15:00:00.000', @Actual = @secStart;
DECLARE @bf1 NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @b1);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.single] nothing backfilled', @Expected = N'0', @Actual = @bf1;
GO

-- =============================================
-- Test 2: overnight backfill (the reported bug). Open Second (Wed 15:00);
--   now = Thu 08:00 -> First. Missed: Second-end 23:00, Third 23:00->07:00.
--   Expect: Second closed 06-10 23:00; Third row 06-10 23:00 -> 06-11 07:00;
--           First open 06-11 07:00; backfilled = 1.
-- =============================================
DECLARE @F2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F2,@S2,@T2);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@S2, '2026-06-10T15:00:00', NULL);
DECLARE @b2 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @b2 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-11T08:00:00', @AppUserId = 1;

DECLARE @secEnd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift WHERE ShiftScheduleId=@S2);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] Second closed at 06-10 23:00',
     @Expected = N'2026-06-10 23:00:00.000', @Actual = @secEnd;

DECLARE @thirdRange NVARCHAR(60) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) + N' | ' + CONVERT(NVARCHAR(30), ActualEnd, 121)
    FROM Oee.Shift WHERE ShiftScheduleId=@T2);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] Third backfilled 23:00->07:00',
     @Expected = N'2026-06-10 23:00:00.000 | 2026-06-11 07:00:00.000', @Actual = @thirdRange;

DECLARE @firstOpen NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift WHERE ShiftScheduleId=@F2 AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] First open at 06-11 07:00',
     @Expected = N'2026-06-11 07:00:00.000', @Actual = @firstOpen;

DECLARE @bf2 NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @b2);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] exactly one shift backfilled', @Expected = N'1', @Actual = @bf2;
GO

-- =============================================
-- Test 3: full-day backfill. Open First (Wed 07:00); now = Thu 08:00 -> First.
--   Missed: First-end 15:00, Second 15-23, Third 23-07. Expect backfilled = 2
--   (Second + Third), First closed 06-10 15:00, new First open 06-11 07:00.
-- =============================================
DECLARE @F3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F3,@S3,@T3);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@F3, '2026-06-10T07:00:00', NULL);
DECLARE @b3 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @b3 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-11T08:00:00', @AppUserId = 1;

DECLARE @bf3 NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @b3);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.fullday] two shifts backfilled', @Expected = N'2', @Actual = @bf3;
DECLARE @totRows NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift WHERE ShiftScheduleId IN (@F3,@S3,@T3)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Backfill.fullday] 4 rows total (First,Second,Third,First)', @Expected = N'4', @Actual = @totRows;
DECLARE @openCnt3 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL AND ShiftScheduleId IN (@F3,@S3,@T3)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Backfill.fullday] exactly one open (B3)', @Expected = N'1', @Actual = @openCnt3;
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
