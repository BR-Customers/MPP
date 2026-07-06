SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/060_OperationTemplateField_SaveAll.sql';
GO

-- Fixture: an OperationTemplate to attach fields to.
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL' AND DeprecatedAt IS NULL);
IF @TemplateId IS NULL
BEGIN
    DECLARE @OpTypeId BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'DieCast');
    INSERT INTO Parts.OperationTemplate (Code, Name, VersionNumber, OperationTypeId, CreatedAt)
    VALUES (N'SA-OTF-TPL', N'Field bundled save test template', 1, @OpTypeId, SYSUTCDATETIME());
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

-- Test 4b: invalid DataCollectionFieldId -> Status=0
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
CREATE TABLE #R4b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4b EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId,
    @RowsJson=N'[{"Id":null,"DataCollectionFieldId":9999999999,"IsRequired":true}]', @AppUserId=1;
SELECT @S = Status FROM #R4b; DROP TABLE #R4b;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveBadDcf] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 5: re-adding a DCF that has TWO historical deprecated rows reactivates exactly one (no unique-index violation)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F3 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'DieInfo');
-- isolate: deprecate all current active fields for this template, then seed two deprecated DieInfo rows
UPDATE Parts.OperationTemplateField SET DeprecatedAt = SYSUTCDATETIME()
  WHERE OperationTemplateId = @TemplateId AND DeprecatedAt IS NULL;
INSERT INTO Parts.OperationTemplateField (OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt, DeprecatedAt)
  VALUES (@TemplateId, @F3, 1, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO Parts.OperationTemplateField (OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt, DeprecatedAt)
  VALUES (@TemplateId, @F3, 1, SYSUTCDATETIME(), SYSUTCDATETIME());
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":null,"DataCollectionFieldId":' + CAST(@F3 AS NVARCHAR(20)) + N',"IsRequired":true}]';
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R5; DROP TABLE #R5;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveMultiDeprecated] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @ActiveCnt INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F3 AND DeprecatedAt IS NULL);
DECLARE @ActiveStr NVARCHAR(10) = CAST(@ActiveCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveMultiDeprecated] Exactly one active DieInfo row', @Expected=N'1', @Actual=@ActiveStr;
GO

-- Test 6: audit Description carries SUBJECT mid-dot Fields mid-dot prefix
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @TypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'OpTemplateField');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId=@TemplateId AND LogEntityTypeId=@TypeId ORDER BY Id DESC);
DECLARE @Pat NVARCHAR(200) = N'SA-OTF-TPL%' + Audit.ufn_MidDot() + N' Fields ' + Audit.ufn_MidDot() + N'%';
DECLARE @Match NVARCHAR(1) = CASE WHEN @Desc LIKE @Pat THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveAudit] Description has SUBJECT mid-dot Fields prefix', @Expected=N'1', @Actual=@Match;
GO

EXEC test.EndTestFile;
GO
