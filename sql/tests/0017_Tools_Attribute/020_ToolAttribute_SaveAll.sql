-- =============================================
-- File:         0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql
-- Description:  Tests for Tools.ToolAttribute_SaveAll (bundled reconcile +
--               per-DataType value validation + hard-delete on absent).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql';
GO

-- Fixture: a Die-type tool + two attribute definitions (String + Integer).
DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL' AND DeprecatedAt IS NULL);
IF @ToolId IS NULL
BEGIN
    DECLARE @ActiveStatus BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
    VALUES (@ToolTypeId, N'SA-ATTR-TOOL', N'Attr bundled save test tool', @ActiveStatus, SYSUTCDATETIME(), 1);
    SET @ToolId = SCOPE_IDENTITY();
END
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAttributeDefinition WHERE ToolTypeId=@ToolTypeId AND Code=N'SA_STR' AND DeprecatedAt IS NULL)
    INSERT INTO Tools.ToolAttributeDefinition (ToolTypeId, Code, Name, DataType) VALUES (@ToolTypeId, N'SA_STR', N'SaveAll String', N'String');
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAttributeDefinition WHERE ToolTypeId=@ToolTypeId AND Code=N'SA_INT' AND DeprecatedAt IS NULL)
    INSERT INTO Tools.ToolAttributeDefinition (ToolTypeId, Code, Name, DataType) VALUES (@ToolTypeId, N'SA_INT', N'SaveAll Integer', N'Integer');
GO

-- Test 1: add a String + Integer attribute (Id=NULL) -> Status=1, 2 rows persist
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @StrDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_STR' AND DeprecatedAt IS NULL);
DECLARE @IntDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_INT' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"ToolAttributeDefinitionId":' + CAST(@StrDef AS NVARCHAR(20)) + N',"Value":"hello"},' +
    N'{"Id":null,"ToolAttributeDefinitionId":' + CAST(@IntDef AS NVARCHAR(20)) + N',"Value":"42"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveAdd] Two rows persist', @Expected=N'2', @Actual=@CntStr;
GO

-- Test 2: update a value + remove the other -> 1 row remains with new value
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @StrDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_STR' AND DeprecatedAt IS NULL);
DECLARE @StrRowId BIGINT = (SELECT Id FROM Tools.ToolAttribute WHERE ToolId=@ToolId AND ToolAttributeDefinitionId=@StrDef);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@StrRowId AS NVARCHAR(20)) + N',"ToolAttributeDefinitionId":' + CAST(@StrDef AS NVARCHAR(20)) + N',"Value":"world"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveUpdRem] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Val NVARCHAR(500) = (SELECT Value FROM Tools.ToolAttribute WHERE Id=@StrRowId);
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveUpdRem] Value updated to world', @Expected=N'world', @Actual=@Val;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveUpdRem] Absent row hard-deleted (1 remains)', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 3: bad Integer value -> Status=0
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @IntDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_INT' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"ToolAttributeDefinitionId":' + CAST(@IntDef AS NVARCHAR(20)) + N',"Value":"notanumber"}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveBadInt] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 4: empty payload clears all rows -> Status=1, 0 rows
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveEmpty] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveEmpty] Zero rows after clear', @Expected=N'0', @Actual=@CntStr;
GO

-- Test 5: Description carries SUBJECT mid-dot Attributes mid-dot prefix
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @TypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ToolAttribute');
DECLARE @StrDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_STR' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"ToolAttributeDefinitionId":' + CAST(@StrDef AS NVARCHAR(20)) + N',"Value":"audit"}]';
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
DROP TABLE #R5;
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId=@ToolId AND LogEntityTypeId=@TypeId ORDER BY Id DESC);
DECLARE @Pat NVARCHAR(200) = N'SA-ATTR-TOOL%' + Audit.ufn_MidDot() + N' Attributes ' + Audit.ufn_MidDot() + N'%';
DECLARE @Match NVARCHAR(1) = CASE WHEN @Desc LIKE @Pat THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveAudit] Description has SUBJECT mid-dot Attributes prefix', @Expected=N'1', @Actual=@Match;
GO

EXEC test.EndTestFile;
GO
