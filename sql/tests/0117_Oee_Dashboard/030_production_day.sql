-- =============================================
-- File:         0117_Oee_Dashboard/030_production_day.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  Production day + period shift sets (OEE dashboard spec
--               docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--               sec 6.6, decision D13): the production day runs
--               3rd -> 1st -> 2nd, so the 3rd shift starting Monday 22:30 is
--               Tuesday's. Production day = the local date the shift's
--               SCHEDULED window ends. Weeks run Monday-Sunday production days.
--
--               Fixture week: Mon 2030-01-07 .. Sun 2030-01-13 (2030-01-01 is a
--               Tuesday), far from any date another suite stamps.
--                 shifts from the 2nd shift of Sun 01-06 (prod day Sun 01-06)
--                 through the 3rd starting Sun 01-13 22:30 (prod day Mon 01-14)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/030_production_day.sql';
GO

-- ---- cleanup + fixture ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_PD_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_PD_%';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_PD_1st', N'1st 06:30-14:30', '06:30:00', '14:30:00', 127, '2020-01-01', 1),
       (N'TEST_PD_2nd', N'2nd 14:30-22:30', '14:30:00', '22:30:00', 127, '2020-01-01', 1),
       (N'TEST_PD_3rd', N'3rd 22:30-06:30', '22:30:00', '06:30:00', 127, '2020-01-01', 1);
GO
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_PD_1st');
DECLARE @S2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_PD_2nd');
DECLARE @S3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_PD_3rd');
-- Sun 01-06 2nd shift: production day Sun 01-06 (previous week).
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@S2, '2030-01-06T14:30:00', '2030-01-06T22:30:00', N'TEST_PD');
-- Each calendar day Sun 01-06 .. Sun 01-13: 3rd at 22:30; Mon 01-07 .. Sun 01-13: 1st + 2nd.
DECLARE @d DATE = '2030-01-06';
WHILE @d <= '2030-01-13'
BEGIN
    IF @d >= '2030-01-07'
    BEGIN
        INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
        VALUES (@S1, DATEADD(MINUTE, 390, CAST(@d AS DATETIME2(3))), DATEADD(MINUTE, 870, CAST(@d AS DATETIME2(3))), N'TEST_PD'),
               (@S2, DATEADD(MINUTE, 870, CAST(@d AS DATETIME2(3))), DATEADD(MINUTE, 1350, CAST(@d AS DATETIME2(3))), N'TEST_PD');
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
    VALUES (@S3, DATEADD(MINUTE, 1350, CAST(@d AS DATETIME2(3))), DATEADD(MINUTE, 1830, CAST(@d AS DATETIME2(3))), N'TEST_PD');
    SET @d = DATEADD(DAY, 1, @d);
END
-- Override: the 3rd shift starting Mon 01-07 22:30 actually ran to 07:45.
UPDATE Oee.Shift SET ActualEnd = '2030-01-08T07:45:00'
WHERE ShiftScheduleId = @S3 AND ActualStart = '2030-01-07T22:30:00';
GO

-- =============================================
-- Test 1: production day of a shift
-- =============================================
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_PD_1st');
DECLARE @S3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_PD_3rd');
DECLARE @MonThird BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @S3 AND ActualStart = '2030-01-07T22:30:00');
DECLARE @MonFirst BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @S1 AND ActualStart = '2030-01-07T06:30:00');
DECLARE @v NVARCHAR(20);

SET @v = (SELECT CONVERT(NVARCHAR(10), ProductionDay, 23) FROM Oee.ufn_ProductionDay(@MonThird));
EXEC test.Assert_IsEqual @TestName = N'[ProdDay] 3rd starting Mon 22:30 -> Tue', @Expected = N'2030-01-08', @Actual = @v;

SET @v = (SELECT CONVERT(NVARCHAR(10), ProductionDay, 23) FROM Oee.ufn_ProductionDay(@MonFirst));
EXEC test.Assert_IsEqual @TestName = N'[ProdDay] 1st Mon 06:30 -> Mon', @Expected = N'2030-01-07', @Actual = @v;

-- @MonThird carries the 07:45 overrun: the SCHEDULED end decides, so still Tue.
SET @v = (SELECT CONVERT(NVARCHAR(10), ProductionDay, 23) FROM Oee.ufn_ProductionDay(@MonThird));
EXEC test.Assert_IsEqual @TestName = N'[ProdDay] overridden 3rd shift keeps scheduled production day', @Expected = N'2030-01-08', @Actual = @v;

DECLARE @none INT = (SELECT COUNT(*) FROM Oee.ufn_ProductionDay(-1));
EXEC test.Assert_RowCount @TestName = N'[ProdDay] unknown shift -> no row', @ExpectedCount = 0, @ActualCount = @none;
GO

-- =============================================
-- Test 2: shift sets for a period
-- =============================================
DECLARE @S1 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_PD_1st');
DECLARE @MonFirst BIGINT = (SELECT Id FROM Oee.Shift WHERE ShiftScheduleId = @S1 AND ActualStart = '2030-01-07T06:30:00');
DECLARE @v NVARCHAR(200);

SET @v = (SELECT STRING_AGG(ss.Name + N'@' + CONVERT(NVARCHAR(16), s.ActualStart, 120), N',') WITHIN GROUP (ORDER BY p.SortKey)
          FROM Oee.ufn_ShiftsForPeriod(N'Day', @MonFirst) p
          INNER JOIN Oee.Shift s ON s.Id = p.ShiftId
          INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId);
EXEC test.Assert_IsEqual @TestName = N'[Period] Day of Mon 1st = {Sun 22:30 3rd, Mon 1st, Mon 2nd}, in that order',
     @Expected = N'TEST_PD_3rd@2030-01-06 22:30,TEST_PD_1st@2030-01-07 06:30,TEST_PD_2nd@2030-01-07 14:30', @Actual = @v;

DECLARE @wk INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftsForPeriod(N'Week', @MonFirst));
EXEC test.Assert_RowCount @TestName = N'[Period] Week holds 21 shifts', @ExpectedCount = 21, @ActualCount = @wk;

SET @v = (SELECT TOP 1 CONVERT(NVARCHAR(16), s.ActualStart, 120)
          FROM Oee.ufn_ShiftsForPeriod(N'Week', @MonFirst) p INNER JOIN Oee.Shift s ON s.Id = p.ShiftId
          ORDER BY p.SortKey);
EXEC test.Assert_IsEqual @TestName = N'[Period] Week starts with the Sun 22:30 3rd shift', @Expected = N'2030-01-06 22:30', @Actual = @v;

SET @v = (SELECT TOP 1 CONVERT(NVARCHAR(16), s.ActualStart, 120)
          FROM Oee.ufn_ShiftsForPeriod(N'Week', @MonFirst) p INNER JOIN Oee.Shift s ON s.Id = p.ShiftId
          ORDER BY p.SortKey DESC);
EXEC test.Assert_IsEqual @TestName = N'[Period] Week ends with the Sun 14:30 2nd shift', @Expected = N'2030-01-13 14:30', @Actual = @v;

DECLARE @one INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftsForPeriod(N'Shift', @MonFirst) WHERE ShiftId = @MonFirst);
DECLARE @all INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftsForPeriod(N'Shift', @MonFirst));
EXEC test.Assert_RowCount @TestName = N'[Period] Shift zoom = the anchor only', @ExpectedCount = 1, @ActualCount = @all;
EXEC test.Assert_RowCount @TestName = N'[Period] Shift zoom row is the anchor', @ExpectedCount = 1, @ActualCount = @one;

DECLARE @unk INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftsForPeriod(N'Day', -1));
EXEC test.Assert_RowCount @TestName = N'[Period] unknown anchor -> 0 rows', @ExpectedCount = 0, @ActualCount = @unk;

DECLARE @bad INT = (SELECT COUNT(*) FROM Oee.ufn_ShiftsForPeriod(N'Month', @MonFirst));
EXEC test.Assert_RowCount @TestName = N'[Period] unknown zoom -> 0 rows', @ExpectedCount = 0, @ActualCount = @bad;
GO

-- ---- cleanup ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_PD_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_PD_%';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
