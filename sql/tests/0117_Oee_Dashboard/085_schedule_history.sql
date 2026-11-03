-- =============================================
-- File:         0117_Oee_Dashboard/085_schedule_history.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-03
-- Description:  A shift schedule change is a line in the sand. A CLOSED shift
--               keeps the window it actually ran (Oee.Shift.ActualStart ->
--               ActualEnd) whatever later happens to its schedule:
--                 1. editing the schedule's times does not move it
--                 2. deprecating the schedule does not hide it
--                 3. an open-ended entry is still capped at the real end
--                 4. a schedule edit does not mark stored shifts stale
--                 5. a per-equipment override for that day still wins
--               Shift 2026-02-03 07:00-15:00 (local); MI carries one real-time
--               entry started 14:30 with no EndedAt -> 30 unplanned minutes.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/085_schedule_history.sql';
GO

EXEC test.OeeFixture_Build;
GO

DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1');
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_SH_%';
DELETE FROM Oee.ShiftOverride WHERE Reason = N'TEST_SH_override';
DELETE FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_SH_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_SH_Day', N'Day 07-15', '07:00:00', '15:00:00', 127, '2020-01-01', 1);
DECLARE @Sched BIGINT = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-02-03T07:00:00', '2026-02-03T15:00:00', N'TEST_SH_S1');
DECLARE @S1 BIGINT = SCOPE_IDENTITY();

DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES (@MI, NULL, @S1,
        CAST(CAST('2026-02-03T14:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
        NULL, @Src, N'TEST_SH_open');
GO

-- One string per check: StartLocal | PlannedMinutes | UnplannedDowntimeMinutes for MI.
IF OBJECT_ID(N'tempdb..#Rf') IS NOT NULL DROP TABLE #Rf;
CREATE TABLE #Rf (Status BIT, Message NVARCHAR(500), ShiftsComputed INT, ShiftsStillStale INT);
IF OBJECT_ID(N'tempdb..#Cp') IS NOT NULL DROP TABLE #Cp;
CREATE TABLE #Cp (Status BIT, Message NVARCHAR(500));
GO

-- ---- baseline ----
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1');
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @v NVARCHAR(200) = (SELECT CONVERT(NVARCHAR(16), StartLocal, 120) + N'|' + CAST(PlannedMinutes AS NVARCHAR(10))
                                   + N'|' + CAST(UnplannedDowntimeMinutes AS NVARCHAR(10))
                            FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationId = @MI);
EXEC test.Assert_IsEqual @TestName = N'[SchedHist] baseline: 07:00, 480 base, 30 unplanned', @Expected = N'2026-02-03 07:00|480|30', @Actual = @v;

-- record the configuration fingerprint, then store this shift
TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
TRUNCATE TABLE #Cp;
INSERT INTO #Cp EXEC Oee.ShiftSummary_Compute @ShiftId = @S1, @AppUserId = 1;
DECLARE @ok NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Cp);
EXEC test.Assert_IsEqual @TestName = N'[SchedHist] shift stored', @Expected = N'1', @Actual = @ok;
GO

-- =============================================
-- 1. editing the schedule's times does not move a closed shift
-- =============================================
UPDATE Oee.ShiftSchedule SET StartTime = '06:00:00', EndTime = '14:00:00' WHERE Name = N'TEST_SH_Day';
GO
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1');
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @v NVARCHAR(200) = (SELECT CONVERT(NVARCHAR(16), StartLocal, 120) + N'|' + CAST(PlannedMinutes AS NVARCHAR(10))
                                   + N'|' + CAST(UnplannedDowntimeMinutes AS NVARCHAR(10))
                            FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationId = @MI);
EXEC test.Assert_IsEqual @TestName = N'[SchedHist] schedule edited: closed shift keeps 07:00, 480, 30', @Expected = N'2026-02-03 07:00|480|30', @Actual = @v;

-- 3. the open-ended entry is capped at the shift's real end (15:00), not the new 14:00
DECLARE @m NVARCHAR(20) = (SELECT CAST(CAST(Minutes AS DECIMAL(12,2)) AS NVARCHAR(20))
                           FROM Oee.ufn_ShiftDowntimeEntries(@S1) WHERE LocationId = @MI);
EXEC test.Assert_IsEqual @TestName = N'[SchedHist] open entry runs to the real end: 30 min', @Expected = N'30.00', @Actual = @m;

-- 4. the schedule edit does not make the stored shift stale
DECLARE @at0 DATETIME2(3) = (SELECT MIN(ComputedAt) FROM Oee.ShiftSummary WHERE ShiftId = @S1);
TRUNCATE TABLE #Rf;
INSERT INTO #Rf EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = 1, @MaxShifts = 100000;
DECLARE @same BIT = CASE WHEN (SELECT MIN(ComputedAt) FROM Oee.ShiftSummary WHERE ShiftId = @S1) = @at0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[SchedHist] schedule edit does not recompute a stored shift', @Condition = @same;
GO

-- =============================================
-- 2. deprecating the schedule does not hide its past shifts
-- =============================================
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME() WHERE Name = N'TEST_SH_Day';
GO
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1');
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @v NVARCHAR(200) = (SELECT CONVERT(NVARCHAR(16), StartLocal, 120) + N'|' + CAST(PlannedMinutes AS NVARCHAR(10))
                                   + N'|' + CAST(UnplannedDowntimeMinutes AS NVARCHAR(10))
                            FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationId = @MI);
EXEC test.Assert_IsEqual @TestName = N'[SchedHist] schedule deprecated: past shift still reports', @Expected = N'2026-02-03 07:00|480|30', @Actual = @v;

TRUNCATE TABLE #Cp;
INSERT INTO #Cp EXEC Oee.ShiftSummary_Compute @ShiftId = @S1, @AppUserId = 1;
DECLARE @kept BIT = CASE WHEN EXISTS (SELECT 1 FROM Oee.ShiftSummary WHERE ShiftId = @S1 AND LocationId = @MI) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[SchedHist] schedule deprecated: recompute keeps the stored row', @Condition = @kept;
GO

-- =============================================
-- 5. an override for that day still wins over the shift's own window
-- =============================================
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
INSERT INTO Oee.ShiftOverride (LocationId, ShiftScheduleId, BusinessDate, StartTime, EndTime, Reason, CreatedByUserId)
SELECT @MI, Id, '2026-02-03', '07:00:00', '17:00:00', N'TEST_SH_override', 1
FROM Oee.ShiftSchedule WHERE Name = N'TEST_SH_Day';
GO
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1');
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @v NVARCHAR(200) = (SELECT CONVERT(NVARCHAR(16), EndLocal, 120) + N'|' + CAST(PlannedMinutes AS NVARCHAR(10))
                                   + N'|' + CAST(IsOverridden AS NVARCHAR(1))
                            FROM Oee.ufn_ShiftAvailability(@S1) WHERE LocationId = @MI);
EXEC test.Assert_IsEqual @TestName = N'[SchedHist] override for the day still wins', @Expected = N'2026-02-03 17:00|600|1', @Actual = @v;
GO

-- ---- cleanup ----
-- the refresh stores every stale shift, so fixture locations can appear under other shifts too
DELETE ss FROM Oee.ShiftSummary ss
WHERE ss.ShiftId IN (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1')
   OR ss.LocationId           IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-OEE%')
   OR ss.ProductionAreaId     IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-OEE%')
   OR ss.ParentUnitLocationId IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-OEE%');
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_SH_%';
DELETE FROM Oee.ShiftOverride WHERE Reason = N'TEST_SH_override';
DELETE FROM Oee.Shift WHERE Remarks = N'TEST_SH_S1';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_SH_Day';
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
