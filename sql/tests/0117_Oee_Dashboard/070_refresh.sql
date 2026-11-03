-- =============================================
-- File:         0117_Oee_Dashboard/070_refresh.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  Oee.ShiftSummary_RefreshChanged (OEE dashboard spec v0.3.2
--               sec 6.8, D19, D22): closed shifts with no stored rows are
--               computed; a late edit within 7 days is found by the input
--               fingerprint; a configuration change (a reason code's
--               IsExcused) reaches even an old shift through the configuration
--               fingerprint; an edit to a shift older than 7 days alone does
--               not (the documented limit, spec 10); @MaxShifts bounds a run.
--               Shifts R1 / R2 are in 2030 (inside "the last 7 days or
--               later"); OLD is 30 days back. Unit ZZ-DSH-DC-M1.
--               The refresh recomputes EVERY stale shift in the database, so
--               the calls use a large @MaxShifts and assertions look only at
--               this file's shifts.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/070_refresh.sql';
GO

-- ---- fixture ----
EXEC test.OeeDashFixture_Build;
GO
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'ZZ-RF%';
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT Id FROM Oee.Shift WHERE Remarks LIKE N'TEST_RF_%');
DELETE FROM Oee.Shift WHERE Remarks LIKE N'TEST_RF_%';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RF_Day';
DELETE FROM Oee.DowntimeReasonCode WHERE Code = N'ZZ-RF-RC';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_RF_Day', N'RF 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1);
DECLARE @Sched BIGINT = SCOPE_IDENTITY();
DECLARE @OldDay DATETIME2(3) = CAST(CAST(DATEADD(DAY, -30, SYSUTCDATETIME()) AS DATE) AS DATETIME2(3));
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2030-05-01T07:01:00', '2030-05-01T15:01:00', N'TEST_RF_R1'),
       (@Sched, '2030-05-02T07:01:00', '2030-05-02T15:01:00', N'TEST_RF_R2'),
       (@Sched, DATEADD(MINUTE, 421, @OldDay), DATEADD(MINUTE, 901, @OldDay), N'TEST_RF_OLD');

INSERT INTO Oee.DowntimeReasonCode (Code, Description, OperationCategoryId, DowntimeReasonTypeId, IsExcused, CreatedByUserId)
VALUES (N'ZZ-RF-RC', N'RF unplanned reason', NULL, (SELECT TOP 1 Id FROM Oee.DowntimeReasonType ORDER BY Id), 0, 1);

DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @Rc BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'ZZ-RF-RC');
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
SELECT @M1, @Rc, s.Id,
       CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
       DATEADD(MINUTE, 30, CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))),
       @Op, N'ZZ-RF base', 1, 30
FROM Oee.Shift s WHERE s.Remarks IN (N'TEST_RF_R1', N'TEST_RF_OLD');
GO

-- one capture table for every refresh call
IF OBJECT_ID(N'tempdb..#Rf') IS NOT NULL DROP TABLE #Rf;
CREATE TABLE #Rf (Status BIT, Message NVARCHAR(500), ShiftsComputed INT, ShiftsStillStale INT);
GO

-- =============================================
-- 1. newly ended shifts computed; an unchanged shift is not recomputed
-- =============================================
TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
DECLARE @v NVARCHAR(100);
SET @v = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Rf) + N'/' + CAST((SELECT COUNT(DISTINCT ss.ShiftId) FROM Oee.ShiftSummary ss
          INNER JOIN Oee.Shift s ON s.Id = ss.ShiftId WHERE s.Remarks LIKE N'TEST_RF_%') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Refresh] newly ended shifts computed (R1, R2, OLD)', @Expected = N'1/3', @Actual = @v;

DECLARE @r1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RF_R1');
DECLARE @at0 DATETIME2(3) = (SELECT MIN(ComputedAt) FROM Oee.ShiftSummary WHERE ShiftId = @r1);
TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
DECLARE @c BIT = CASE WHEN (SELECT MIN(ComputedAt) FROM Oee.ShiftSummary WHERE ShiftId = @r1) = @at0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Refresh] unchanged shift not recomputed (ComputedAt same)', @Condition = @c;
GO

-- =============================================
-- 2. a late entry within 7 days is picked up
-- =============================================
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @r1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RF_R1');
DECLARE @r2 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RF_R2');
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @At DATETIME2(3) = (SELECT CAST(ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) FROM Oee.Shift WHERE Id = @r1);
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
VALUES (@M1, NULL, @r1, @At, DATEADD(MINUTE, 20, @At), @Op, N'ZZ-RF late', 1, 20);

TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
DECLARE @v NVARCHAR(100) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(20)) FROM Oee.ShiftSummary WHERE ShiftId = @r1 AND RowKind = N'Unit' AND LocationId = @M1);
EXEC test.Assert_IsEqual @TestName = N'[Refresh] late downtime entry -> recomputed, minutes updated (30 + 20)', @Expected = N'50.00', @Actual = @v;

-- 3. the entry is re-attributed to R2 (what ShiftOverride_Restamp writes)
UPDATE Oee.DowntimeEvent SET ShiftId = @r2 WHERE Remarks = N'ZZ-RF late';
TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
SET @v = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(20)) FROM Oee.ShiftSummary WHERE ShiftId = @r1 AND RowKind = N'Unit' AND LocationId = @M1)
       + N'/' + (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(20)) FROM Oee.ShiftSummary WHERE ShiftId = @r2 AND RowKind = N'Unit' AND LocationId = @M1);
EXEC test.Assert_IsEqual @TestName = N'[Refresh] moved entry -> both shifts recomputed', @Expected = N'30.00/20.00', @Actual = @v;
GO

-- =============================================
-- 4. a shift older than 7 days: a late edit alone is NOT picked up (spec 10)
-- =============================================
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @old BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RF_OLD');
DECLARE @Rc BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'ZZ-RF-RC');
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @At DATETIME2(3) = (SELECT CAST(ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) FROM Oee.Shift WHERE Id = @old);
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
VALUES (@M1, @Rc, @old, @At, DATEADD(MINUTE, 15, @At), @Op, N'ZZ-RF old late', 1, 15);

TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
DECLARE @v NVARCHAR(100) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(20)) FROM Oee.ShiftSummary WHERE ShiftId = @old AND RowKind = N'Unit' AND LocationId = @M1);
EXEC test.Assert_IsEqual @TestName = N'[Refresh] shift older than 7 days with a late edit NOT recomputed', @Expected = N'30.00', @Actual = @v;

-- =============================================
-- 5. a configuration change reaches the old shift (IsExcused flipped)
-- =============================================
DECLARE @Desc NVARCHAR(500) = (SELECT Description FROM Oee.DowntimeReasonCode WHERE Id = @Rc);
DECLARE @Type BIGINT = (SELECT DowntimeReasonTypeId FROM Oee.DowntimeReasonCode WHERE Id = @Rc);
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @st EXEC Oee.DowntimeReasonCode_Update @Id = @Rc, @Description = @Desc, @DowntimeReasonTypeId = @Type, @IsExcused = 1, @AppUserId = 1;
SET @v = (SELECT CAST(Status AS NVARCHAR(1)) FROM @st);
EXEC test.Assert_IsEqual @TestName = N'[Refresh] fixture: DowntimeReasonCode_Update IsExcused = 1 succeeds', @Expected = N'1', @Actual = @v;

TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
SET @v = (SELECT CAST(PlannedDowntimeMinutes AS NVARCHAR(20)) + N'/' + CAST(UnplannedDowntimeMinutes AS NVARCHAR(20))
          FROM Oee.ShiftSummary WHERE ShiftId = @old AND RowKind = N'Unit' AND LocationId = @M1);
EXEC test.Assert_IsEqual @TestName = N'[Refresh] IsExcused flip -> old shift recomputed (45 planned, 0 unplanned)', @Expected = N'45.00/0.00', @Actual = @v;
GO

-- =============================================
-- 6. @MaxShifts bounds a run
-- =============================================
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT Id FROM Oee.Shift WHERE Remarks IN (N'TEST_RF_R1', N'TEST_RF_R2'));
TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 1;
DECLARE @v NVARCHAR(100) = (SELECT CAST(ShiftsComputed AS NVARCHAR(10)) + N'/' + CAST(ShiftsStillStale AS NVARCHAR(10)) FROM #Rf);
EXEC test.Assert_IsEqual @TestName = N'[Refresh] @MaxShifts bounds the work, ShiftsStillStale reports the rest', @Expected = N'1/1', @Actual = @v;
SET @v = (SELECT CAST(COUNT(DISTINCT ShiftId) AS NVARCHAR(10)) FROM Oee.ShiftSummary
          WHERE ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_RF_R2'));
EXEC test.Assert_IsEqual @TestName = N'[Refresh] newest stale shift first (R2)', @Expected = N'1', @Actual = @v;
GO

-- ---- cleanup ----
DROP TABLE #Rf;
DELETE ss FROM Oee.ShiftSummary ss
WHERE ss.ShiftId IN (SELECT Id FROM Oee.Shift WHERE Remarks LIKE N'TEST_RF_%')
   OR ss.LocationId           IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-DSH%')
   OR ss.ProductionAreaId     IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-DSH%')
   OR ss.ParentUnitLocationId IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-DSH%');
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'ZZ-RF%';
DELETE FROM Oee.Shift WHERE Remarks LIKE N'TEST_RF_%';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RF_Day';
EXEC test.OeeDashFixture_Teardown;
DELETE FROM Oee.DowntimeReasonCode WHERE Code = N'ZZ-RF-RC';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
