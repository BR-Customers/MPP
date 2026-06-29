-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/050_EndOfShiftEntry_Submit.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 end-of-shift time entry (FDS-09-013).
--               Asserts: selected breaks write one CLOSED DowntimeEvent each with
--               the schedule-resolved (StandardDurationMinutes) duration; re-submit
--               for the same shift is rejected; a closed shift is rejected; zero
--               breaks is valid (no rows).
--               NB: Oee.Shift enforces UIX_Shift_SingleOpen (one open shift at a
--               time) -- the test opens shift A, closes it, then opens shift B.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/050_EndOfShiftEntry_Submit.sql';
GO

IF OBJECT_ID(N'tempdb..#EosFix') IS NOT NULL DROP TABLE #EosFix;
CREATE TABLE #EosFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

-- Defensive: clear any leftover test schedules/shifts (prior aborted run).
DELETE de FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift s ON s.Id = de.ShiftId
    INNER JOIN Oee.ShiftSchedule sc ON sc.Id = s.ShiftScheduleId WHERE sc.Name LIKE N'P8 EOS%';
DELETE s FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule sc ON sc.Id = s.ShiftScheduleId WHERE sc.Name LIKE N'P8 EOS%';
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'P8 EOS%';
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
-- Ensure break reason codes exist: the 0012 DowntimeReasonCode tests run earlier
-- and wipe the table, so re-seed our breaks idempotently (the Break type survives).
DECLARE @SiteId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @BreakTypeId BIGINT = (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break');
INSERT INTO Oee.DowntimeReasonCode (Code, Description, AreaLocationId, DowntimeReasonTypeId, IsExcused, StandardDurationMinutes, CreatedByUserId)
SELECT v.Code, v.Descr, @SiteId, @BreakTypeId, 1, v.Mins, 1
FROM (VALUES (N'LUNCH', N'Scheduled lunch', 30), (N'BREAK1', N'Scheduled break 1', 15), (N'BREAK2', N'Scheduled break 2', 15)) v(Code, Descr, Mins)
WHERE NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode rc WHERE rc.Code = v.Code);
DECLARE @Lunch  BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');
DECLARE @Break1 BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'BREAK1');

DECLARE @schedA BIGINT, @schedB BIGINT, @shiftA BIGINT;
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'P8 EOS Test A', '06:00', '14:00', 31, '2026-01-01', 1);
SET @schedA = SCOPE_IDENTITY();
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'P8 EOS Test B', '14:00', '22:00', 31, '2026-01-01', 1);
SET @schedB = SCOPE_IDENTITY();
-- only ONE open shift at a time (UIX_Shift_SingleOpen)
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@schedA, SYSUTCDATETIME());
SET @shiftA = SCOPE_IDENTITY();

INSERT INTO #EosFix (Tag, Val) VALUES
    (N'CELL', @CellId), (N'LUNCH', @Lunch), (N'BREAK1', @Break1),
    (N'SCHEDA', @schedA), (N'SCHEDB', @schedB), (N'SHIFTA', @shiftA);
GO

-- =============================================
-- Test 1: submit two breaks -> 2 closed events with resolved durations
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'CELL');
DECLARE @ShiftA BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SHIFTA');
DECLARE @L BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'LUNCH');
DECLARE @B BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'BREAK1');
DECLARE @json NVARCHAR(50) = N'[' + CAST(@L AS NVARCHAR(20)) + N',' + CAST(@B AS NVARCHAR(20)) + N']';
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), EventCountInserted INT);
INSERT INTO @r1 EXEC Oee.EndOfShiftEntry_Submit
    @ShiftId = @ShiftA, @CellLocationId = @Cell, @BreaksSelectedJson = @json, @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @r1);
DECLARE @cnt1 INT = (SELECT EventCountInserted FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[EOS] submit two breaks succeeds (Status=1)', @Condition = @ok1;
DECLARE @cnt1str NVARCHAR(10) = CAST(@cnt1 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[EOS] EventCountInserted = 2', @Expected = N'2', @Actual = @cnt1str;
DECLARE @rows1 INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE ShiftId = @ShiftA AND EndedAt IS NOT NULL);
EXEC test.Assert_RowCount @TestName = N'[EOS] two closed events written for the shift', @ExpectedCount = 2, @ActualCount = @rows1;
DECLARE @lunchDur INT = (SELECT DATEDIFF(MINUTE, StartedAt, EndedAt) FROM Oee.DowntimeEvent WHERE ShiftId = @ShiftA AND DowntimeReasonCodeId = @L);
DECLARE @lunchDurStr NVARCHAR(10) = CAST(@lunchDur AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[EOS] lunch event duration resolved to 30 min', @Expected = N'30', @Actual = @lunchDurStr;
GO

-- =============================================
-- Test 2: re-submit for the same shift rejected
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'CELL');
DECLARE @ShiftA BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SHIFTA');
DECLARE @L BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'LUNCH');
DECLARE @json2 NVARCHAR(50) = N'[' + CAST(@L AS NVARCHAR(20)) + N']';
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), EventCountInserted INT);
INSERT INTO @r2 EXEC Oee.EndOfShiftEntry_Submit
    @ShiftId = @ShiftA, @CellLocationId = @Cell, @BreaksSelectedJson = @json2, @AppUserId = 1;
DECLARE @c2 BIT = CASE WHEN (SELECT Status FROM @r2) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[EOS] re-submit for same shift rejected', @Condition = @c2;
GO

-- =============================================
-- Test 3: a closed shift is rejected (close shift A, then submit)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'CELL');
DECLARE @ShiftA BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SHIFTA');
DECLARE @L BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'LUNCH');
UPDATE Oee.Shift SET ActualEnd = SYSUTCDATETIME() WHERE Id = @ShiftA;
DECLARE @json3 NVARCHAR(50) = N'[' + CAST(@L AS NVARCHAR(20)) + N']';
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), EventCountInserted INT);
INSERT INTO @r3 EXEC Oee.EndOfShiftEntry_Submit
    @ShiftId = @ShiftA, @CellLocationId = @Cell, @BreaksSelectedJson = @json3, @AppUserId = 1;
DECLARE @c3 BIT = CASE WHEN (SELECT Status FROM @r3) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[EOS] closed shift rejected', @Condition = @c3;
GO

-- =============================================
-- Test 4: zero breaks is valid (open shift B now that A is closed)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'CELL');
DECLARE @SchedB BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SCHEDB');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@SchedB, SYSUTCDATETIME());
DECLARE @ShiftB BIGINT = SCOPE_IDENTITY();
INSERT INTO #EosFix (Tag, Val) VALUES (N'SHIFTB', @ShiftB);
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), EventCountInserted INT);
INSERT INTO @r4 EXEC Oee.EndOfShiftEntry_Submit
    @ShiftId = @ShiftB, @CellLocationId = @Cell, @BreaksSelectedJson = N'[]', @AppUserId = 1;
DECLARE @ok4 BIT = (SELECT Status FROM @r4);
DECLARE @cnt4 INT = (SELECT EventCountInserted FROM @r4);
EXEC test.Assert_IsTrue @TestName = N'[EOS] zero breaks is valid (Status=1)', @Condition = @ok4;
DECLARE @cnt4str NVARCHAR(10) = CAST(@cnt4 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[EOS] zero breaks writes no events', @Expected = N'0', @Actual = @cnt4str;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @shiftA BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SHIFTA');
DECLARE @shiftB BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SHIFTB');
DECLARE @schedA BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SCHEDA');
DECLARE @schedB BIGINT = (SELECT Val FROM #EosFix WHERE Tag = N'SCHEDB');
DELETE ol FROM Audit.OperationLog ol
    WHERE ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent')
      AND ol.EntityId IN (@shiftA, @shiftB);
DELETE FROM Oee.DowntimeEvent WHERE ShiftId IN (@shiftA, @shiftB);
DELETE FROM Oee.Shift WHERE Id IN (@shiftA, @shiftB);
DELETE FROM Oee.ShiftSchedule WHERE Id IN (@schedA, @schedB);
IF OBJECT_ID(N'tempdb..#EosFix') IS NOT NULL DROP TABLE #EosFix;
GO
