SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/020_ToolCavity_SaveAll.sql';
GO

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL' AND DeprecatedAt IS NULL);
IF @ToolId IS NULL
BEGIN
    DECLARE @ActiveStatus BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
    VALUES (@ToolTypeId, N'SA-CAV-TOOL', N'Cavity bundled save test tool', @ActiveStatus, SYSUTCDATETIME(), 1);
    SET @ToolId = SCOPE_IDENTITY();
END
-- Clear any cavities from prior runs (hard delete: test isolation only)
DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;
GO

-- Test 1: add cavity #1 (Active) -> Status=1, one active row
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":null,"CavityNumber":1,"Description":"Cav one","StatusCode":"Active"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId=@ToolId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveAdd] One active cavity', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 2: change #1 to Scrapped -> Status=1, status persists
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityNumber=1 AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityNumber":1,"Description":"Cav one","StatusCode":"Scrapped"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveScrap] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @StatusCode NVARCHAR(20) = (SELECT sc.Code FROM Tools.ToolCavity c INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id=c.StatusCodeId WHERE c.Id=@CavId);
EXEC test.Assert_IsEqual @TestName=N'[CavSaveScrap] Status is Scrapped', @Expected=N'Scrapped', @Actual=@StatusCode;
GO

-- Test 3: try to un-scrap #1 -> Status=0 (Scrapped lock)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityNumber=1);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityNumber":1,"Description":"Cav one","StatusCode":"Active"}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveUnscrap] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 4: change CavityNumber on existing row -> Status=0 (immutable)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityNumber=1);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityNumber":99,"Description":"Cav one","StatusCode":"Scrapped"}]';
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveImmutableNum] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 5: empty payload does NOT delete cavities (insert+update only)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R5; DROP TABLE #R5;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmpty] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmpty] Cavity persists (not deleted on absent)', @Expected=N'1', @Actual=@CntStr;
GO

EXEC test.EndTestFile;
GO
