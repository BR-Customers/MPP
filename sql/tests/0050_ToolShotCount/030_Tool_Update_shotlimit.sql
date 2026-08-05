SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/030_Tool_Update_shotlimit.sql';
GO
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-SHOT-UPD', N'TEST-SHOT-CUT');
GO
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @CutType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Cutter');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-UPD', N'Shot update test die', @Active, SYSUTCDATETIME(), 1);
DECLARE @Die BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@CutType, N'TEST-SHOT-CUT', N'Shot update test cutter', @Active, SYSUTCDATETIME(), 1);
DECLARE @Cut BIGINT = SCOPE_IDENTITY();

-- set a limit on the die
DECLARE @U TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U EXEC Tools.Tool_Update @Id=@Die, @Name=N'Shot update test die', @Description=NULL,
    @DieRankId=NULL, @ShotLimit=5000, @AppUserId=1;
DECLARE @us NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @U);
EXEC test.Assert_IsEqual @TestName=N'[Update] set ShotLimit on die -> Status 1', @Expected=N'1', @Actual=@us;
DECLARE @slAfter NVARCHAR(20) = (SELECT CAST(ShotLimit AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Update] die ShotLimit persisted 5000', @Expected=N'5000', @Actual=@slAfter;

-- clear the limit
DELETE FROM @U;
INSERT INTO @U EXEC Tools.Tool_Update @Id=@Die, @Name=N'Shot update test die', @Description=NULL,
    @DieRankId=NULL, @ShotLimit=NULL, @AppUserId=1;
DECLARE @slCleared NVARCHAR(20) = (SELECT ISNULL(CAST(ShotLimit AS NVARCHAR(20)), N'NULL') FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Update] die ShotLimit cleared to NULL', @Expected=N'NULL', @Actual=@slCleared;

-- non-die rejection
DELETE FROM @U;
INSERT INTO @U EXEC Tools.Tool_Update @Id=@Cut, @Name=N'Shot update test cutter', @Description=NULL,
    @DieRankId=NULL, @ShotLimit=100, @AppUserId=1;
DECLARE @cs NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @U);
EXEC test.Assert_IsEqual @TestName=N'[Update] ShotLimit on non-die -> Status 0', @Expected=N'0', @Actual=@cs;
DECLARE @cslAfter NVARCHAR(20) = (SELECT ISNULL(CAST(ShotLimit AS NVARCHAR(20)), N'NULL') FROM Tools.Tool WHERE Id=@Cut);
EXEC test.Assert_IsEqual @TestName=N'[Update] non-die ShotLimit not written', @Expected=N'NULL', @Actual=@cslAfter;

DELETE FROM Tools.Tool WHERE Id IN (@Die, @Cut);
GO
EXEC test.EndTestFile;
GO
