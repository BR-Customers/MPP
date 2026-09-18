-- =============================================
-- File:         0090_Oee_EnabledLocations/040_write_validation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Oee.DowntimeEvent_Start / _RecordHistorical / _RecordApproximate
--               accept a flagged location and refuse an unflagged one. The
--               refusal is what keeps downtime off terminals, stores and areas
--               now that the flag -- not the hierarchy -- decides.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/040_write_validation.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- =============================================
-- Test 1: Start accepts a flagged station.
-- =============================================
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r1 EXEC Oee.DowntimeEvent_Start @LocationId = @A, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r1);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] Start accepts a flagged station',
     @Expected = N'1', @Actual = @s1;
GO

-- =============================================
-- Test 2: Start refuses the terminal on that same line.
-- =============================================
DECLARE @T   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r2 EXEC Oee.DowntimeEvent_Start @LocationId = @T, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r2);
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @r2);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] Start refuses an unflagged terminal',
     @Expected = N'0', @Actual = @s2;
EXEC test.Assert_Contains @TestName = N'[DtWrite] the refusal says the location is not enabled for downtime',
     @HaystackStr = @m2, @NeedleStr = N'not enabled for downtime';

DECLARE @leaked INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE LocationId = @T);
EXEC test.Assert_RowCount @TestName = N'[DtWrite] the refused Start wrote no event',
     @ExpectedCount = 0, @ActualCount = @leaked;
GO

-- =============================================
-- Test 3: RecordHistorical refuses an unflagged location, accepts a flagged one.
-- =============================================
DECLARE @T  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @St DATETIME2(3) = DATEADD(HOUR, -3, SYSDATETIME());
DECLARE @En DATETIME2(3) = DATEADD(HOUR, -2, SYSDATETIME());

DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3 EXEC Oee.DowntimeEvent_RecordHistorical
    @ScopeLocationId = @T, @StartedAtEt = @St, @EndedAtEt = @En, @AppUserId = 1;
DECLARE @s3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r3);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordHistorical refuses an unflagged location',
     @Expected = N'0', @Actual = @s3;

DECLARE @r3b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3b EXEC Oee.DowntimeEvent_RecordHistorical
    @ScopeLocationId = @MI, @StartedAtEt = @St, @EndedAtEt = @En, @AppUserId = 1;
DECLARE @s3b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r3b);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordHistorical accepts a flagged station',
     @Expected = N'1', @Actual = @s3b;
GO

-- =============================================
-- Test 4: RecordApproximate, same pair.
-- =============================================
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-E-STORE');
DECLARE @B     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-B');

DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4 EXEC Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId = @Store, @DurationMinutes = 15, @AppUserId = 1;
DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r4);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordApproximate refuses a storage location',
     @Expected = N'0', @Actual = @s4;

DECLARE @r4b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4b EXEC Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId = @B, @DurationMinutes = 15, @AppUserId = 1;
DECLARE @s4b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r4b);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordApproximate accepts a flagged station',
     @Expected = N'1', @Actual = @s4b;
GO

-- =============================================
-- Test 5: a flagged but DEPRECATED machine is refused (the existing not-found
-- check fires first; the outcome is what matters).
-- =============================================
DECLARE @M3  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M3');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5 EXEC Oee.DowntimeEvent_Start @LocationId = @M3, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r5);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] a deprecated machine is refused',
     @Expected = N'0', @Actual = @s5;
GO

EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
