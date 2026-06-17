-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/090_Handover_and_OpenSummary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-17
-- Description:  Arc 2 Phase 8 dashboard + summary support procs:
--                 * Oee.DowntimeEvent_GetOpenSummary -> counts (split consistency)
--                 * Oee.ShiftHandover_Acknowledge    -> audit-only acknowledge
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/090_Handover_and_OpenSummary.sql';
GO

-- =============================================
-- Test 1: open-summary counts are internally consistent
-- =============================================
DECLARE @sum TABLE (TotalOpen INT, WithReason INT, WithoutReason INT);
INSERT INTO @sum EXEC Oee.DowntimeEvent_GetOpenSummary;
DECLARE @tot INT = (SELECT TotalOpen FROM @sum);
DECLARE @wr  INT = (SELECT WithReason FROM @sum);
DECLARE @wo  INT = (SELECT WithoutReason FROM @sum);
DECLARE @consistent BIT = CASE WHEN (ISNULL(@wr,0) + ISNULL(@wo,0)) = ISNULL(@tot,0) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Dash] open-summary WithReason + WithoutReason = TotalOpen', @Condition = @consistent;
GO

-- =============================================
-- Test 2/3: handover acknowledge (happy + not-found)
-- =============================================
IF OBJECT_ID(N'tempdb..#HoFix') IS NOT NULL DROP TABLE #HoFix;
CREATE TABLE #HoFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
DELETE s FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule sc ON sc.Id = s.ShiftScheduleId WHERE sc.Name LIKE N'P8 HO%';
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'P8 HO%';
DECLARE @sched BIGINT, @shift BIGINT;
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'P8 HO Test', '06:00', '14:00', 31, '2026-01-01', 1);
SET @sched = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@sched, SYSUTCDATETIME());
SET @shift = SCOPE_IDENTITY();
INSERT INTO #HoFix (Tag, Val) VALUES (N'SCHED', @sched), (N'SHIFT', @shift);

DECLARE @a TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @a EXEC Oee.ShiftHandover_Acknowledge @ShiftId = @shift, @AppUserId = 1;
DECLARE @okA BIT = (SELECT Status FROM @a);
EXEC test.Assert_IsTrue @TestName = N'[Handover] acknowledge succeeds (Status=1)', @Condition = @okA;
DECLARE @audit INT = (SELECT COUNT(*) FROM Audit.OperationLog
                      WHERE EntityId = @shift
                        AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ShiftHandoverAcknowledged'));
EXEC test.Assert_RowCount @TestName = N'[Handover] acknowledge wrote an audit row', @ExpectedCount = 1, @ActualCount = @audit;

DECLARE @b TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @b EXEC Oee.ShiftHandover_Acknowledge @ShiftId = 99999999, @AppUserId = 1;
DECLARE @c3 BIT = CASE WHEN (SELECT Status FROM @b) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Handover] acknowledge of unknown shift rejected', @Condition = @c3;
GO

-- ---- cleanup ----
DECLARE @shift BIGINT = (SELECT Val FROM #HoFix WHERE Tag = N'SHIFT');
DECLARE @sched BIGINT = (SELECT Val FROM #HoFix WHERE Tag = N'SCHED');
DELETE FROM Audit.OperationLog WHERE EntityId = @shift
    AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ShiftHandoverAcknowledged');
DELETE FROM Oee.Shift WHERE Id = @shift;
DELETE FROM Oee.ShiftSchedule WHERE Id = @sched;
IF OBJECT_ID(N'tempdb..#HoFix') IS NOT NULL DROP TABLE #HoFix;
GO
