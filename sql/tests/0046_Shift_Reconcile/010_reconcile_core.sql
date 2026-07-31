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

-- ---- cleanup ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
