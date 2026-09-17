SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/060_Tool_CorrectShotCount.sql';
GO
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-SHOT-FIX', N'TEST-SHOT-FIXCUT', N'TEST-SHOT-FIXDEP');
GO
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @CutType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Cutter');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @ToolEntity BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Tool');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-FIX', N'Shot fix test die', @Active, 1000, SYSUTCDATETIME(), 1);
DECLARE @Die BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@CutType, N'TEST-SHOT-FIXCUT', N'Shot fix test cutter', @Active, SYSUTCDATETIME(), 1);
DECLARE @Cut BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId, DeprecatedAt)
VALUES (@DieType, N'TEST-SHOT-FIXDEP', N'Shot fix deprecated die', @Active, 50, SYSUTCDATETIME(), 1, SYSUTCDATETIME());
DECLARE @Dep BIGINT = SCOPE_IDENTITY();

DECLARE @ContribBefore INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @v NVARCHAR(4000);

-- [Up] 1000 -> 850000 with a note
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=850000,
    @ExpectedShotCount=1000, @Note=N'Cutover: count from die card', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Up] Status 1', @Expected=N'1', @Actual=@v;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Up] ShotCount = 850000', @Expected=N'850000', @Actual=@v;

-- [Audit] one ConfigLog row with old/new/delta/note
SET @v = (SELECT TOP 1 Description FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName=N'[Audit] description names the category', @HaystackStr=@v, @NeedleStr=N'Shot Count';
EXEC test.Assert_Contains @TestName=N'[Audit] description shows old count', @HaystackStr=@v, @NeedleStr=N'1,000';
EXEC test.Assert_Contains @TestName=N'[Audit] description shows new count', @HaystackStr=@v, @NeedleStr=N'850,000';
EXEC test.Assert_Contains @TestName=N'[Audit] description carries the note', @HaystackStr=@v, @NeedleStr=N'die card';
SET @v = (SELECT TOP 1 JSON_VALUE(NewValue, '$.Delta') FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName=N'[Audit] NewValue.Delta = 849000', @Expected=N'849000', @Actual=@v;
SET @v = (SELECT TOP 1 JSON_VALUE(NewValue, '$.Note') FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName=N'[Audit] NewValue.Note is the full note', @Expected=N'Cutover: count from die card', @Actual=@v;
SET @v = (SELECT TOP 1 JSON_VALUE(OldValue, '$.ShotCount') FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName=N'[Audit] OldValue.ShotCount = 1000', @Expected=N'1000', @Actual=@v;

-- [Down] 850000 -> 849990 (negative delta allowed)
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=849990,
    @ExpectedShotCount=850000, @Note=N'Typo fix', @AppUserId=1;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Down] ShotCount = 849990', @Expected=N'849990', @Actual=@v;

-- [Zero] to 0 is legal
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=0,
    @ExpectedShotCount=849990, @Note=N'Die rebuilt', @AppUserId=1;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Zero] ShotCount = 0', @Expected=N'0', @Actual=@v;

DECLARE @AuditCount INT = (SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die);

-- [Reject] blank note
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=10,
    @ExpectedShotCount=0, @Note=N'   ', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] blank note', @Expected=N'0|A note is required when changing the shot count.', @Actual=@v;

-- [Reject] NULL note
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=10,
    @ExpectedShotCount=0, @Note=NULL, @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] NULL note -> Status 0', @Expected=N'0', @Actual=@v;

-- [Reject] negative
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=-1,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] negative', @Expected=N'0|Shot count cannot be negative.', @Actual=@v;

-- [Reject] unchanged
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=0,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] unchanged', @Expected=N'0|Shot count is unchanged.', @Actual=@v;

-- [Reject] stale: screen loaded 500 but the die is at 0
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=900,
    @ExpectedShotCount=500, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] stale expected count',
    @Expected=N'0|Shot count changed since this die was opened (now 0). Reload and re-enter.', @Actual=@v;

-- [Reject] non-Die
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Cut, @ShotCount=10,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] non-Die', @Expected=N'0|Shot count is only tracked for Die-type Tools.', @Actual=@v;

-- [Reject] deprecated
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Dep, @ShotCount=60,
    @ExpectedShotCount=50, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] deprecated', @Expected=N'0|Tool not found or deprecated.', @Actual=@v;

-- [Reject] missing required
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=NULL,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] missing ShotCount', @Expected=N'0|Required parameter missing.', @Actual=@v;

-- [NoSideEffects] rejections wrote nothing; no contribution rows ever
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[NoSideEffects] ShotCount still 0', @Expected=N'0', @Actual=@v;
SET @v = CAST((SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die) AS NVARCHAR(10));
DECLARE @AuditExpected NVARCHAR(10) = CAST(@AuditCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[NoSideEffects] no ConfigLog rows from rejections', @Expected=@AuditExpected, @Actual=@v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution) AS NVARCHAR(10));
DECLARE @ContribExpected NVARCHAR(10) = CAST(@ContribBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[NoSideEffects] no DieCastContribution rows written', @Expected=@ContribExpected, @Actual=@v;

DELETE FROM Tools.Tool WHERE Id IN (@Die, @Cut, @Dep);
GO
EXEC test.EndTestFile;
GO
