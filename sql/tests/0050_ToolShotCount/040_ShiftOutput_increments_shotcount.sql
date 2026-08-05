SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/040_ShiftOutput_increments_shotcount.sql';
GO
DELETE FROM Tools.Tool WHERE Code = N'TEST-SHOT-INC';
GO
-- fixture: a Die tool (the increment target) + a resolved/minted open shift.
-- Empty @LinesJson means the proc records no per-cavity output and only the
-- gross-shot increment runs, so no Cell/Item/Cavity/basket is needed.
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-INC', N'Shot increment test die', @Active, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0050/040 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- first submission: gross 500 -> ShotCount 500
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=500;
DECLARE @s1 NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Inc] gross 500 -> Status 1', @Expected=N'1', @Actual=@s1;
DECLARE @c1 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] ShotCount = 500 after first submit', @Expected=N'500', @Actual=@c1;

-- second submission: gross 300 -> accumulates to 800
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=300;
DECLARE @c2 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] ShotCount accumulates to 800', @Expected=N'800', @Actual=@c2;

-- NULL gross: no-op (mirrors registerShotLoss's no-gross path)
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=NULL;
DECLARE @c3 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] NULL gross leaves ShotCount at 800', @Expected=N'800', @Actual=@c3;

-- zero gross: no-op
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=0;
DECLARE @c4 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] zero gross leaves ShotCount at 800', @Expected=N'800', @Actual=@c4;

-- negative gross: rejected pre-transaction, no increment
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=-1;
DECLARE @s5 NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Inc] negative gross -> Status 0', @Expected=N'0', @Actual=@s5;
DECLARE @c5 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] negative gross leaves ShotCount at 800', @Expected=N'800', @Actual=@c5;

-- gross supplied but a bad lot line -> validation rejects before the txn -> no increment
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[{"lotId":999999999,"pieceDelta":1,"scrapLines":null}]',
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=100;
DECLARE @s6 NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Inc] gross + bad lot -> Status 0', @Expected=N'0', @Actual=@s6;
DECLARE @c6 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] failed submit does not bump ShotCount (still 800)', @Expected=N'800', @Actual=@c6;

-- teardown
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
