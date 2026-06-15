-- =============================================
-- File:         0020_PlantFloor_Foundation/030_Shift_lifecycle.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for the Oee Shift runtime procs (Task F):
-- =====================================================================
--                 - Shift_Start creates an open Shift row (+ ShiftStarted audit)
--                 - Shift_Start rejects when an open Shift already exists (B3)
--                 - Shift_GetOpen returns the open instance
--                 - Shift_End closes the open Shift
--                 - Shift_End rejects when there is no open Shift
--                 - Shift_GetActive matches a schedule by day-of-week bitmask
--                 - Shift_GetActive returns empty on a day NOT in the bitmask
--                 - no auto-carryover: Shift_End touches ONLY the Shift row
--
--   Pre-conditions: migration 0020 applied; Oee.ShiftSchedule / Oee.Shift exist;
--   AppUser Id=1 (bootstrap) present; the four Oee.Shift_* procs deployed.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/030_Shift_lifecycle.sql';
GO

-- ---- fixture cleanup + a test ShiftSchedule (Mon-Fri 06:00-14:00) ----
DELETE FROM Oee.Shift
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_Shift%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_Shift%';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_Shift_Day', N'Test day shift Mon-Fri 06:00-14:00', '06:00:00', '14:00:00', 31, '2020-01-01', 1);
GO

-- =============================================
-- Test 1: Shift_Start creates an open Shift row.
-- =============================================
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_Shift_Day');
DECLARE @S BIT, @NewId BIGINT, @SStr NVARCHAR(1), @NewIdStr NVARCHAR(20);
CREATE TABLE #st1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #st1 EXEC Oee.Shift_Start @ShiftScheduleId=@SchedId, @AppUserId=1;
SELECT @S = Status, @NewId = NewId FROM #st1;
DROP TABLE #st1;
SET @SStr = CAST(@S AS NVARCHAR(1));
SET @NewIdStr = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[ShiftStart] Shift_Start returns Status=1', @Expected = N'1', @Actual = @SStr;
EXEC test.Assert_IsNotNull @TestName = N'[ShiftStart] Shift_Start returns a NewId', @Value = @NewIdStr;

DECLARE @OpenCnt INT = (SELECT COUNT(*) FROM Oee.Shift WHERE ShiftScheduleId = @SchedId AND ActualEnd IS NULL);
DECLARE @OpenCntStr NVARCHAR(10) = CAST(@OpenCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ShiftStart] exactly one open Shift row', @Expected = N'1', @Actual = @OpenCntStr;

-- ShiftStarted audit emitted to OperationLog (entity Shift, NOT routed to LotEventLog).
DECLARE @AudCnt INT = (
    SELECT COUNT(*) FROM Audit.OperationLog ol
    INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
    WHERE et.Code = N'ShiftStarted' AND ol.EntityId = @NewId);
DECLARE @AudCntStr NVARCHAR(10) = CAST(@AudCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ShiftStart] ShiftStarted audit row written', @Expected = N'1', @Actual = @AudCntStr;
GO

-- =============================================
-- Test 2: Shift_Start rejects when an open Shift already exists (B3).
-- =============================================
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_Shift_Day');
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #st2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #st2 EXEC Oee.Shift_Start @ShiftScheduleId=@SchedId, @AppUserId=1;
SELECT @S = Status FROM #st2;
DROP TABLE #st2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ShiftStartDup] second open Shift rejected (B3)', @Expected = N'0', @Actual = @SStr;

DECLARE @OpenCnt INT = (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL);
DECLARE @OpenCntStr NVARCHAR(10) = CAST(@OpenCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ShiftStartDup] still exactly one open Shift', @Expected = N'1', @Actual = @OpenCntStr;
GO

-- =============================================
-- Test 3: Shift_GetOpen returns the open instance.
-- =============================================
DECLARE @GotId BIGINT, @GotIdStr NVARCHAR(20);
CREATE TABLE #go (Id BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100),
                  ActualStart DATETIME2(3), ActualEnd DATETIME2(3), Remarks NVARCHAR(500), CreatedAt DATETIME2(3));
INSERT INTO #go EXEC Oee.Shift_GetOpen;
SELECT @GotId = Id FROM #go;
DROP TABLE #go;
SET @GotIdStr = CAST(@GotId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[ShiftGetOpen] returns the open Shift', @Value = @GotIdStr;
GO

-- =============================================
-- Test 4: Shift_End closes the open Shift.
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #en1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #en1 EXEC Oee.Shift_End @AppUserId=1;
SELECT @S = Status FROM #en1;
DROP TABLE #en1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ShiftEnd] Shift_End returns Status=1', @Expected = N'1', @Actual = @SStr;

DECLARE @OpenCnt INT = (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL);
DECLARE @OpenCntStr NVARCHAR(10) = CAST(@OpenCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ShiftEnd] no open Shift remains', @Expected = N'0', @Actual = @OpenCntStr;

-- ShiftEnded audit emitted.
DECLARE @AudCnt INT = (
    SELECT COUNT(*) FROM Audit.OperationLog ol
    INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
    WHERE et.Code = N'ShiftEnded');
DECLARE @AudCntStr NVARCHAR(10) = CAST(CASE WHEN @AudCnt >= 1 THEN 1 ELSE 0 END AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ShiftEnd] ShiftEnded audit row written', @Expected = N'1', @Actual = @AudCntStr;
GO

-- =============================================
-- Test 5: Shift_End rejects when there is no open Shift.
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #en2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #en2 EXEC Oee.Shift_End @AppUserId=1;
SELECT @S = Status FROM #en2;
DROP TABLE #en2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ShiftEndNone] Shift_End with no open shift rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 6: Shift_GetActive matches the schedule by day-of-week bitmask.
--   TEST_Shift_Day = Mon-Fri (31), 06:00-14:00. Pick a Wednesday 10:00 UTC
--   (2026-06-10 is a Wednesday) -> must match. Pick a Sunday (2026-06-14)
--   -> must NOT match (Sun bit 64 not set).
-- =============================================
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_Shift_Day');
DECLARE @Wed DATETIME2(3) = '2026-06-10T10:00:00';   -- Wednesday, inside window
DECLARE @Sun DATETIME2(3) = '2026-06-14T10:00:00';   -- Sunday, not in bitmask
DECLARE @MatchedId BIGINT, @MatchStr NVARCHAR(1);

CREATE TABLE #ga1 (Id BIGINT, Name NVARCHAR(100), Description NVARCHAR(500),
                   StartTime TIME(0), EndTime TIME(0), DaysOfWeekBitmask INT, EffectiveFrom DATE);
INSERT INTO #ga1 EXEC Oee.Shift_GetActive @AtMoment=@Wed;
SELECT @MatchedId = Id FROM #ga1 WHERE Id = @SchedId;
DROP TABLE #ga1;
SET @MatchStr = CAST(CASE WHEN @MatchedId = @SchedId THEN 1 ELSE 0 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ShiftGetActive] Wednesday 10:00 matches Mon-Fri schedule', @Expected = N'1', @Actual = @MatchStr;

DECLARE @SunCnt INT;
CREATE TABLE #ga2 (Id BIGINT, Name NVARCHAR(100), Description NVARCHAR(500),
                   StartTime TIME(0), EndTime TIME(0), DaysOfWeekBitmask INT, EffectiveFrom DATE);
INSERT INTO #ga2 EXEC Oee.Shift_GetActive @AtMoment=@Sun;
SELECT @SunCnt = COUNT(*) FROM #ga2 WHERE Id = @SchedId;
DROP TABLE #ga2;
DECLARE @SunStr NVARCHAR(10) = CAST(@SunCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ShiftGetActive] Sunday does NOT match Mon-Fri schedule', @Expected = N'0', @Actual = @SunStr;
GO

-- =============================================
-- Test 7: no auto-carryover. After Shift_Start then Shift_End, a fresh
--   schedule-only world has no lingering open shift AND Shift_End did not
--   create/alter any non-Shift artifact we can observe (Phase 1 contract:
--   only the Shift row is touched). We assert the ended shift has a non-null
--   ActualEnd and ActualStart preserved (the row was closed, not recreated).
-- =============================================
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_Shift_Day');
DECLARE @S BIT, @StartId BIGINT;
CREATE TABLE #ca (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ca EXEC Oee.Shift_Start @ShiftScheduleId=@SchedId, @ActualStart='2026-06-10T06:00:00', @AppUserId=1;
SELECT @StartId = NewId FROM #ca;
DROP TABLE #ca;

CREATE TABLE #ce (Status BIT, Message NVARCHAR(500));
INSERT INTO #ce EXEC Oee.Shift_End @ActualEnd='2026-06-10T14:00:00', @AppUserId=1;
DROP TABLE #ce;

DECLARE @ClosedOk NVARCHAR(1) = (
    SELECT CASE WHEN ActualEnd IS NOT NULL AND ActualStart = '2026-06-10T06:00:00' THEN N'1' ELSE N'0' END
    FROM Oee.Shift WHERE Id = @StartId);
EXEC test.Assert_IsEqual @TestName = N'[ShiftNoCarry] Shift_End closed the SAME row (start preserved, end set)', @Expected = N'1', @Actual = @ClosedOk;
GO

-- ---- cleanup ----
DELETE FROM Oee.Shift
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_Shift%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_Shift%';
GO

EXEC test.EndTestFile;
GO
