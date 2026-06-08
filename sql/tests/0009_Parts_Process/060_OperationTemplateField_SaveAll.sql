SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/060_OperationTemplateField_SaveAll.sql';
GO

-- Fixture: an OperationTemplate to attach fields to.
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL' AND DeprecatedAt IS NULL);
IF @TemplateId IS NULL
BEGIN
    DECLARE @AreaId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                              INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                              INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
                              WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL ORDER BY l.Code);
    INSERT INTO Parts.OperationTemplate (Code, Name, VersionNumber, AreaLocationId, CreatedAt)
    VALUES (N'SA-OTF-TPL', N'Field bundled save test template', 1, @AreaId, SYSUTCDATETIME());
    SET @TemplateId = SCOPE_IDENTITY();
END
-- Clean prior junctions for isolation
UPDATE Parts.OperationTemplateField SET DeprecatedAt = SYSUTCDATETIME()
WHERE OperationTemplateId = @TemplateId AND DeprecatedAt IS NULL;
GO

-- Test 1: add two fields (Id=NULL) -> Status=1, two active rows
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'Weight');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'GoodCount');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"DataCollectionFieldId":' + CAST(@F1 AS NVARCHAR(20)) + N',"IsRequired":true},' +
    N'{"Id":null,"DataCollectionFieldId":' + CAST(@F2 AS NVARCHAR(20)) + N',"IsRequired":false}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveAdd] Two active fields', @Expected=N'2', @Actual=@CntStr;
GO

-- Test 2: flip one IsRequired + remove the other -> 1 active row, IsRequired flipped
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'Weight');
DECLARE @J1 BIGINT = (SELECT Id FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F1 AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@J1 AS NVARCHAR(20)) + N',"DataCollectionFieldId":' + CAST(@F1 AS NVARCHAR(20)) + N',"IsRequired":false}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveUpdRem] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Req BIT = (SELECT IsRequired FROM Parts.OperationTemplateField WHERE Id=@J1);
DECLARE @ReqStr NVARCHAR(1) = CAST(@Req AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveUpdRem] IsRequired flipped to 0', @Expected=N'0', @Actual=@ReqStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveUpdRem] One active field after remove', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 3: re-add the removed field (Id=NULL) reactivates rather than duplicating
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'Weight');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'GoodCount');
DECLARE @J1 BIGINT = (SELECT Id FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F1 AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@J1 AS NVARCHAR(20)) + N',"DataCollectionFieldId":' + CAST(@F1 AS NVARCHAR(20)) + N',"IsRequired":false},' +
    N'{"Id":null,"DataCollectionFieldId":' + CAST(@F2 AS NVARCHAR(20)) + N',"IsRequired":true}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveReact] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @DistinctRows INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F2);
DECLARE @DRStr NVARCHAR(10) = CAST(@DistinctRows AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveReact] GoodCount reactivated, not duplicated', @Expected=N'1', @Actual=@DRStr;
GO

-- Test 4: bad template id -> Status=0
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=9999999999, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveBadTpl] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

EXEC test.EndTestFile;
GO
