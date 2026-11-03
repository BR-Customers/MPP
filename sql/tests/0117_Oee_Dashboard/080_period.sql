-- =============================================
-- File:         0117_Oee_Dashboard/080_period.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  Oee.Dashboard_GetPeriod (OEE dashboard spec v0.3.2 sec 5.1,
--               6.6, 6.8): default anchor = the last ENDED shift; previous /
--               next by shift, production day (3rd -> 1st -> 2nd) and week;
--               never past the shift in progress; labels; the "entries may
--               still be arriving" flag for a shift closed under an hour ago.
--               Shifts (2031, later than any other fixture):
--                 Sun 07-06 22:30 3rd   -> production day Mon 7/7
--                 Mon 07-07 06:30 1st   -> Mon
--                 Mon 07-07 14:30 2nd   -> Mon
--                 Mon 07-07 22:30 3rd   -> Tue 7/8   (last ENDED shift)
--                 Tue 07-08 06:30 1st   -> Tue       (OPEN)
--               plus a shift that ended 20 minutes ago (recently closed).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/080_period.sql';
GO

DELETE FROM Oee.Shift WHERE Remarks LIKE N'TEST_PD_%';
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'PD-%';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'PD-1st', N'PD 1st', '06:30:00', '14:30:00', 127, '2020-01-01', 1),
       (N'PD-2nd', N'PD 2nd', '14:30:00', '22:30:00', 127, '2020-01-01', 1),
       (N'PD-3rd', N'PD 3rd', '22:30:00', '06:30:00', 127, '2020-01-01', 1);
DECLARE @s1 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'PD-1st');
DECLARE @s2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'PD-2nd');
DECLARE @s3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'PD-3rd');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@s3, '2031-07-06T22:30:00', '2031-07-07T06:30:00', N'TEST_PD_Sun3'),
       (@s1, '2031-07-07T06:30:00', '2031-07-07T14:30:00', N'TEST_PD_Mon1'),
       (@s2, '2031-07-07T14:30:00', '2031-07-07T22:30:00', N'TEST_PD_Mon2'),
       (@s3, '2031-07-07T22:30:00', '2031-07-08T06:30:00', N'TEST_PD_Mon3');
IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
    VALUES (@s1, '2031-07-08T06:30:00', NULL, N'TEST_PD_Tue1');
-- ended 20 minutes ago (local wall clock, OI-38)
DECLARE @NowLocal DATETIME2(0) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0));
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@s1, DATEADD(MINUTE, -500, @NowLocal), DATEADD(MINUTE, -20, @NowLocal), N'TEST_PD_Recent');
GO

IF OBJECT_ID(N'tempdb..#P') IS NOT NULL DROP TABLE #P;
CREATE TABLE #P (AnchorShiftId BIGINT, Zoom NVARCHAR(5), PeriodLabel NVARCHAR(100), IsInProgress BIT, HasNext BIT, IsRecentlyClosed BIT);
GO

DECLARE @Sun3 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_PD_Sun3');
DECLARE @Mon1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_PD_Mon1');
DECLARE @Mon2 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_PD_Mon2');
DECLARE @Mon3 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_PD_Mon3');
DECLARE @Tue1 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_PD_Tue1');
DECLARE @Rec  BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_PD_Recent');
DECLARE @v NVARCHAR(200), @e NVARCHAR(200);

-- default anchor
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = NULL, @Step = 0;
SET @v = (SELECT CAST(AnchorShiftId AS NVARCHAR(20)) + N'|' + PeriodLabel FROM #P);
SET @e = CAST(@Mon3 AS NVARCHAR(20)) + N'|PD-3rd - Tue 7/8';
EXEC test.Assert_IsEqual @TestName = N'[Period] default anchor is last ENDED shift, labelled with its production day', @Expected = @e, @Actual = @v;

-- day and week labels
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Day', @AnchorShiftId = @Mon1, @Step = 0;
SET @v = (SELECT PeriodLabel FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Period] Day label', @Expected = N'Production day Mon 7/7', @Actual = @v;
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Week', @AnchorShiftId = @Mon1, @Step = 0;
SET @v = (SELECT PeriodLabel FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Period] Week label', @Expected = N'Week of Mon 7/7', @Actual = @v;

-- Day -1 from Tuesday's day -> Monday's day (its last shift, the 2nd)
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Day', @AnchorShiftId = @Mon3, @Step = -1;
SET @v = (SELECT CAST(AnchorShiftId AS NVARCHAR(20)) + N'|' + PeriodLabel FROM #P);
SET @e = CAST(@Mon2 AS NVARCHAR(20)) + N'|Production day Mon 7/7';
EXEC test.Assert_IsEqual @TestName = N'[Period] Step -1 at Day -> previous production day', @Expected = @e, @Actual = @v;

-- Shift -1 from Mon 1st -> Sunday's 3rd
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = @Mon1, @Step = -1;
SET @v = (SELECT CAST(AnchorShiftId AS NVARCHAR(20)) FROM #P);
SET @e = CAST(@Sun3 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Period] Step -1 at Shift -> previous shift', @Expected = @e, @Actual = @v;

-- onto the open shift, and not past it
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = @Mon3, @Step = 1;
SET @v = (SELECT CAST(AnchorShiftId AS NVARCHAR(20)) + N'|' + CAST(IsInProgress AS NVARCHAR(1)) + N'|' + CAST(HasNext AS NVARCHAR(1)) FROM #P);
SET @e = CAST(@Tue1 AS NVARCHAR(20)) + N'|1|0';
EXEC test.Assert_IsEqual @TestName = N'[Period] Step +1 onto the open shift -> IsInProgress 1', @Expected = @e, @Actual = @v;
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = @Tue1, @Step = 1;
SET @v = (SELECT CAST(AnchorShiftId AS NVARCHAR(20)) + N'|' + CAST(HasNext AS NVARCHAR(1)) FROM #P);
SET @e = CAST(@Tue1 AS NVARCHAR(20)) + N'|0';
EXEC test.Assert_IsEqual @TestName = N'[Period] Step +1 from the open shift -> HasNext 0, anchor unchanged', @Expected = @e, @Actual = @v;
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = @Mon2, @Step = 0;
SET @v = (SELECT CAST(HasNext AS NVARCHAR(1)) + N'|' + CAST(IsInProgress AS NVARCHAR(1)) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Period] an ended shift with a later one -> HasNext 1, not in progress', @Expected = N'1|0', @Actual = @v;

-- recently closed
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = @Rec, @Step = 0;
SET @v = (SELECT CAST(IsRecentlyClosed AS NVARCHAR(1)) FROM #P);
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Shift', @AnchorShiftId = @Mon2, @Step = 0;
SET @v = @v + N'|' + (SELECT CAST(IsRecentlyClosed AS NVARCHAR(1)) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Period] shift ended 20 min ago -> IsRecentlyClosed 1 (an old one 0)', @Expected = N'1|0', @Actual = @v;

-- unknown anchor
TRUNCATE TABLE #P;
INSERT INTO #P EXEC Oee.Dashboard_GetPeriod @Zoom = N'Day', @AnchorShiftId = -1, @Step = 0;
DECLARE @n INT = (SELECT COUNT(*) FROM #P);
EXEC test.Assert_RowCount @TestName = N'[Period] unknown anchor -> 0 rows', @ExpectedCount = 0, @ActualCount = @n;
GO

-- ---- cleanup ----
DROP TABLE #P;
DELETE FROM Oee.Shift WHERE Remarks LIKE N'TEST_PD_%';
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'PD-%';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
