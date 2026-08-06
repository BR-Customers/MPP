-- =============================================
-- File:         0012_Oee_Reference/020_DowntimeReasonCode_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-15
-- Description:
--   Tests for Oee.DowntimeReasonCode CRUD procs (Phase 8):
--     Oee.DowntimeReasonCode_Create
--     Oee.DowntimeReasonCode_Get
--     Oee.DowntimeReasonCode_List
--     Oee.DowntimeReasonCode_Update
--     Oee.DowntimeReasonCode_Deprecate
--
--   Pre-conditions:
--     - Migrations 0001-0009 applied
--     - AppUser Id=1 exists (bootstrap admin)
--     - MPP plant seed (011): at least one active ProductionArea (DefId 3),
--       resolved dynamically per batch (@Cat) rather than by seed Id/Code
--
--   NOTE: Code is immutable on Update by design — there is no @Code
--         parameter on Oee.DowntimeReasonCode_Update. To change a code
--         the caller must Deprecate the row and Create a new one.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0012_Oee_Reference/020_DowntimeReasonCode_crud.sql';
GO

-- =============================================
-- Test: Create happy path — Status=1, NewId > 0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TEST-DRC-001',
    @Description          = N'Test downtime reason 001',
    @OperationCategoryId       = @Cat,         -- Die Cast
    @DowntimeReasonTypeId = 1,         -- Equipment
    @IsExcused            = 0,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'DRC_Create[HappyPath]: NewId is not NULL',
    @Value    = @NewIdStr;

DECLARE @NewIdGtZero NVARCHAR(1) = CASE WHEN @NewId > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[HappyPath]: NewId is greater than 0',
    @Expected = N'1',
    @Actual   = @NewIdGtZero;
GO

-- =============================================
-- Test: Create with NULL DowntimeReasonTypeId — Status=1 (nullable per Q-B)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TEST-DRC-002',
    @Description          = N'Test downtime reason with NULL type',
    @OperationCategoryId       = @Cat,
    @DowntimeReasonTypeId = NULL,
    @IsExcused            = 0,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[NullType]: status is 1 (TypeId is nullable)',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test: Create duplicate Code — Status=0, message mentions duplicate
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TEST-DRC-001',  -- duplicate of first test
    @Description          = N'Duplicate code attempt',
    @OperationCategoryId       = @Cat,
    @DowntimeReasonTypeId = 1,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[DupCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'DRC_Create[DupCode]: message mentions already exists',
    @HaystackStr = @M,
    @NeedleStr   = N'already exists';
GO

-- =============================================
-- Test: Create with NULL Description — Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TEST-DRC-NULL-DESC',
    @Description          = NULL,
    @OperationCategoryId       = @Cat,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[NullDesc]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test: Create with invalid OperationCategoryId — Status=0, message mentions Area
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TEST-DRC-BAD-AREA',
    @Description          = N'Invalid area test',
    @OperationCategoryId       = 999999,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[BadArea]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'DRC_Create[BadArea]: message mentions OperationCategoryId',
    @HaystackStr = @M,
    @NeedleStr   = N'OperationCategoryId';
GO

-- =============================================
-- Test: Create with invalid DowntimeReasonTypeId — Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6 EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TEST-DRC-BAD-TYPE',
    @Description          = N'Invalid type test',
    @OperationCategoryId       = @Cat,
    @DowntimeReasonTypeId = 99,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[BadType]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'DRC_Create[BadType]: message mentions DowntimeReasonTypeId',
    @HaystackStr = @M,
    @NeedleStr   = N'DowntimeReasonTypeId';
GO

-- =============================================
-- Test: Get returns 1 row with right Code/Description/OperationCategoryId
-- =============================================
DECLARE @TargetId BIGINT;
SELECT @TargetId = Id FROM Oee.DowntimeReasonCode WHERE Code = N'TEST-DRC-001';

DECLARE @Count INT;
CREATE TABLE #G (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    DowntimeReasonTypeId BIGINT, ReasonTypeName NVARCHAR(100),
    DowntimeSourceCodeId BIGINT, SourceCodeName NVARCHAR(100),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #G EXEC Oee.DowntimeReasonCode_Get @Id = @TargetId;
SELECT @Count = COUNT(*) FROM #G;

DECLARE @GotCode  NVARCHAR(20)  = (SELECT TOP 1 Code FROM #G);
DECLARE @GotDesc  NVARCHAR(500) = (SELECT TOP 1 Description FROM #G);
DECLARE @GotArea  BIGINT        = (SELECT TOP 1 OperationCategoryId FROM #G);
DECLARE @GotAreaStr NVARCHAR(20) = CAST(@GotArea AS NVARCHAR(20));
DECLARE @Cat    BIGINT      = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @CatStr NVARCHAR(20) = CAST(@Cat AS NVARCHAR(20));
DROP TABLE #G;

EXEC test.Assert_RowCount
    @TestName      = N'DRC_Get[HappyPath]: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;

EXEC test.Assert_IsEqual
    @TestName = N'DRC_Get[HappyPath]: Code matches',
    @Expected = N'TEST-DRC-001',
    @Actual   = @GotCode;

EXEC test.Assert_IsEqual
    @TestName = N'DRC_Get[HappyPath]: Description matches',
    @Expected = N'Test downtime reason 001',
    @Actual   = @GotDesc;

EXEC test.Assert_IsEqual
    @TestName = N'DRC_Get[HappyPath]: OperationCategoryId matches the created area',
    @Expected = @CatStr,
    @Actual   = @GotAreaStr;
GO

-- =============================================
-- Test: Get with missing Id — empty result (0 rows)
-- =============================================
DECLARE @Count INT;
CREATE TABLE #G (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    DowntimeReasonTypeId BIGINT, ReasonTypeName NVARCHAR(100),
    DowntimeSourceCodeId BIGINT, SourceCodeName NVARCHAR(100),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #G EXEC Oee.DowntimeReasonCode_Get @Id = 999999;
SELECT @Count = COUNT(*) FROM #G;
DROP TABLE #G;

EXEC test.Assert_RowCount
    @TestName      = N'DRC_Get[Missing]: empty result',
    @ExpectedCount = 0,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test: List filter by OperationCategoryId — at least 1 row, all with matching Area
-- =============================================
DECLARE @TargetId BIGINT;
SELECT @TargetId = Id FROM Oee.DowntimeReasonCode WHERE Code = N'TEST-DRC-001';

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #L (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    DowntimeReasonTypeId BIGINT, ReasonTypeName NVARCHAR(100),
    DowntimeSourceCodeId BIGINT, SourceCodeName NVARCHAR(100),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #L EXEC Oee.DowntimeReasonCode_List
    @OperationCategoryId    = @Cat,
    @IncludeDeprecated = 0;

DECLARE @TotalCount INT       = (SELECT COUNT(*) FROM #L);
DECLARE @MatchCount INT       = (SELECT COUNT(*) FROM #L WHERE OperationCategoryId = @Cat OR OperationCategoryId IS NULL);
DECLARE @ContainsTarget INT   = (SELECT COUNT(*) FROM #L WHERE Id = @TargetId);
DROP TABLE #L;

DECLARE @AllMatch NVARCHAR(1) =
    CASE WHEN @TotalCount > 0 AND @TotalCount = @MatchCount THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_List[FilterByArea]: all returned rows match the filtered area',
    @Expected = N'1',
    @Actual   = @AllMatch;

DECLARE @ContainsStr NVARCHAR(1) =
    CASE WHEN @ContainsTarget = 1 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_List[FilterByArea]: includes our created TEST-DRC-001',
    @Expected = N'1',
    @Actual   = @ContainsStr;
GO

-- =============================================
-- Test: List filter by DowntimeReasonTypeId=1 — all rows match TypeId=1
-- =============================================
CREATE TABLE #L2 (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    DowntimeReasonTypeId BIGINT, ReasonTypeName NVARCHAR(100),
    DowntimeSourceCodeId BIGINT, SourceCodeName NVARCHAR(100),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #L2 EXEC Oee.DowntimeReasonCode_List
    @DowntimeReasonTypeId = 1,
    @IncludeDeprecated    = 0;

DECLARE @T2Total INT     = (SELECT COUNT(*) FROM #L2);
DECLARE @T2Match INT     = (SELECT COUNT(*) FROM #L2 WHERE DowntimeReasonTypeId = 1);
DROP TABLE #L2;

DECLARE @T2All NVARCHAR(1) =
    CASE WHEN @T2Total > 0 AND @T2Total = @T2Match THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_List[FilterByType]: all returned rows have TypeId=1',
    @Expected = N'1',
    @Actual   = @T2All;
GO

-- =============================================
-- Test: Update happy path — Status=1; Get confirms new Description + UpdatedAt set
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Oee.DowntimeReasonCode WHERE Code = N'TEST-DRC-001';

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R7 EXEC Oee.DowntimeReasonCode_Update
    @Id                   = @TargetId,
    @Description          = N'Test downtime reason 001 (updated)',
    @OperationCategoryId       = @Cat,
    @DowntimeReasonTypeId = 2,         -- changed Equipment -> Miscellaneous
    @IsExcused            = 1,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message FROM #R7;
DROP TABLE #R7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredDesc  NVARCHAR(500);
DECLARE @StoredUpdAt DATETIME2(3);
DECLARE @StoredUpdBy BIGINT;
SELECT @StoredDesc  = Description,
       @StoredUpdAt = UpdatedAt,
       @StoredUpdBy = UpdatedByUserId
FROM Oee.DowntimeReasonCode WHERE Id = @TargetId;

EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[HappyPath]: Description changed',
    @Expected = N'Test downtime reason 001 (updated)',
    @Actual   = @StoredDesc;

DECLARE @UpdAtSet NVARCHAR(1) =
    CASE WHEN @StoredUpdAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[HappyPath]: UpdatedAt is set',
    @Expected = N'1',
    @Actual   = @UpdAtSet;

DECLARE @UpdByStr NVARCHAR(20) = CAST(@StoredUpdBy AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[HappyPath]: UpdatedByUserId is 1',
    @Expected = N'1',
    @Actual   = @UpdByStr;
GO

-- =============================================
-- Test: Update with invalid Id — Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R8 EXEC Oee.DowntimeReasonCode_Update
    @Id                   = 999999,
    @Description          = N'Should fail',
    @OperationCategoryId       = @Cat,
    @IsExcused            = 0,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message FROM #R8;
DROP TABLE #R8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[BadId]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test: Deprecate happy path — Status=1, DeprecatedAt set
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Oee.DowntimeReasonCode WHERE Code = N'TEST-DRC-002';

CREATE TABLE #R9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R9 EXEC Oee.DowntimeReasonCode_Deprecate
    @Id        = @TargetId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R9;
DROP TABLE #R9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Deprecate[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Oee.DowntimeReasonCode WHERE Id = @TargetId;
DECLARE @DepStr NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Deprecate[HappyPath]: DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @DepStr;
GO

-- =============================================
-- Test: Deprecate already-deprecated — Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Oee.DowntimeReasonCode WHERE Code = N'TEST-DRC-002';

CREATE TABLE #R10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R10 EXEC Oee.DowntimeReasonCode_Deprecate
    @Id        = @TargetId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R10;
DROP TABLE #R10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Deprecate[AlreadyDeprecated]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'DRC_Deprecate[AlreadyDeprecated]: message mentions already',
    @HaystackStr = @M,
    @NeedleStr   = N'already';
GO

-- =============================================
-- Slice 8 (audit-readability): Create Description carries
--   "Downtime Code <Code> — <Name> (<CategoryName>, Excused) · Created"
--   and NewValue JSON carries a resolved Area sub-object.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #RS8a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RS8a EXEC Oee.DowntimeReasonCode_Create
    @Code                 = N'TST-DT-S8',
    @Description          = N'Mechanical',
    @OperationCategoryId       = @Cat,         -- Die Cast
    @DowntimeReasonTypeId = 1,
    @IsExcused            = 1,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RS8a;
DROP TABLE #RS8a;

DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeReasonCode');

DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @NewId AND LogEntityTypeId = @EntTypeId
                               ORDER BY Id DESC);
DECLARE @CreatePattern NVARCHAR(300) =
    N'Downtime Code TST-DT-S8 ' + NCHAR(8212) + N' Mechanical (%, Excused) '
    + Audit.ufn_MidDot() + N' Created';
DECLARE @CreateMatch NVARCHAR(1) = CASE WHEN @Desc LIKE @CreatePattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[S8Activity]: Description matches SUBJECT mid-dot Created',
    @Expected = N'1',
    @Actual   = @CreateMatch;

DECLARE @NewVal NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Audit.ConfigLog
                                 WHERE EntityId = @NewId AND LogEntityTypeId = @EntTypeId
                                 ORDER BY Id DESC);
DECLARE @CreateJson NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@NewVal, '$.Category.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Create[S8Json]: NewValue has resolved Area.Name',
    @Expected = N'1',
    @Actual   = @CreateJson;
GO

-- =============================================
-- Slice 8: Update Description carries the field-diff list with
--   boolean rendered as words and string fields quoted.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @TargetId BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'TST-DT-S8');

DECLARE @Cat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
CREATE TABLE #RS8b (Status BIT, Message NVARCHAR(500));
INSERT INTO #RS8b EXEC Oee.DowntimeReasonCode_Update
    @Id                   = @TargetId,
    @Description          = N'Mechanical Failure',
    @OperationCategoryId       = @Cat,
    @DowntimeReasonTypeId = 1,
    @IsExcused            = 0,         -- flip true -> false
    @AppUserId            = 1;
SELECT @S = Status, @M = Message FROM #RS8b;
DROP TABLE #RS8b;

DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeReasonCode');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @TargetId AND LogEntityTypeId = @EntTypeId
                               ORDER BY Id DESC);
DECLARE @UpdPattern NVARCHAR(400) =
    N'Downtime Code TST-DT-S8 ' + Audit.ufn_MidDot()
    + N' Updated Name "Mechanical" ' + NCHAR(8594) + N' "Mechanical Failure"%Excused true '
    + NCHAR(8594) + N' false%';
DECLARE @UpdMatch NVARCHAR(1) = CASE WHEN @Desc LIKE @UpdPattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[S8Activity]: Description has Name diff + Excused true->false words',
    @Expected = N'1',
    @Actual   = @UpdMatch;

DECLARE @OldVal NVARCHAR(MAX) = (SELECT TOP 1 OldValue FROM Audit.ConfigLog
                                 WHERE EntityId = @TargetId AND LogEntityTypeId = @EntTypeId
                                 ORDER BY Id DESC);
DECLARE @UpdJson NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@OldVal, '$.Category.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Update[S8Json]: OldValue has resolved Area.Name',
    @Expected = N'1',
    @Actual   = @UpdJson;
GO

-- =============================================
-- Slice 8: Deprecate Description is verb-form; OldValue resolved.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @TargetId BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'TST-DT-S8');

CREATE TABLE #RS8c (Status BIT, Message NVARCHAR(500));
INSERT INTO #RS8c EXEC Oee.DowntimeReasonCode_Deprecate
    @Id = @TargetId, @AppUserId = 1;
DROP TABLE #RS8c;

DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeReasonCode');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @TargetId AND LogEntityTypeId = @EntTypeId
                               ORDER BY Id DESC);
DECLARE @DepPattern NVARCHAR(200) =
    N'Downtime Code TST-DT-S8 ' + Audit.ufn_MidDot() + N' Deprecated';
DECLARE @DepMatch NVARCHAR(1) = CASE WHEN @Desc LIKE @DepPattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Deprecate[S8Activity]: Description is "<Code> mid-dot Deprecated"',
    @Expected = N'1',
    @Actual   = @DepMatch;

DECLARE @OldVal NVARCHAR(MAX) = (SELECT TOP 1 OldValue FROM Audit.ConfigLog
                                 WHERE EntityId = @TargetId AND LogEntityTypeId = @EntTypeId
                                 ORDER BY Id DESC);
DECLARE @DepJson NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@OldVal, '$.Category.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DRC_Deprecate[S8Json]: OldValue has resolved Area.Name',
    @Expected = N'1',
    @Actual   = @DepJson;
GO

-- =============================================
-- Plant-wide create (NULL category) succeeds
-- =============================================
DECLARE @Spw BIT;
CREATE TABLE #PW (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #PW EXEC Oee.DowntimeReasonCode_Create
    @Code = N'TEST-DRC-PW', @Description = N'Plant-wide downtime', @OperationCategoryId = NULL, @IsExcused = 0, @AppUserId = 1;
SELECT @Spw = Status FROM #PW; DROP TABLE #PW;
DECLARE @PWStr NVARCHAR(1) = CAST(@Spw AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'DRC_Create[PlantWide]: status is 1', @Expected = N'1', @Actual = @PWStr;
GO

-- =============================================
-- List by OperationTypeCode 'DieCast' returns die-cast + plant-wide, excludes Trim
-- =============================================
DECLARE @TrimCat BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
CREATE TABLE #CT (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CT EXEC Oee.DowntimeReasonCode_Create
    @Code = N'TEST-DRC-TRIM', @Description = N'Trim only downtime', @OperationCategoryId = @TrimCat, @IsExcused = 0, @AppUserId = 1;
DROP TABLE #CT;

CREATE TABLE #LT (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    DowntimeReasonTypeId BIGINT, ReasonTypeName NVARCHAR(100),
    DowntimeSourceCodeId BIGINT, SourceCodeName NVARCHAR(100),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #LT EXEC Oee.DowntimeReasonCode_List @OperationTypeCode = N'DieCast', @IncludeDeprecated = 0;
DECLARE @HasDC   NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LT WHERE Code = N'TEST-DRC-001')  THEN N'1' ELSE N'0' END;
DECLARE @HasPW   NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LT WHERE Code = N'TEST-DRC-PW')   THEN N'1' ELSE N'0' END;
DECLARE @HasTrim NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LT WHERE Code = N'TEST-DRC-TRIM') THEN N'1' ELSE N'0' END;
DROP TABLE #LT;
EXEC test.Assert_IsEqual @TestName = N'DRC_List[ByType]: die-cast code present',  @Expected = N'1', @Actual = @HasDC;
EXEC test.Assert_IsEqual @TestName = N'DRC_List[ByType]: plant-wide code present', @Expected = N'1', @Actual = @HasPW;
EXEC test.Assert_IsEqual @TestName = N'DRC_List[ByType]: trim code excluded',      @Expected = N'0', @Actual = @HasTrim;
GO

-- =============================================
-- List by OperationCategoryCode 'DieCast' (plant-floor terminal scoping path):
-- same category+plant-wide inclusion, trim excluded, via the category CODE.
-- =============================================
CREATE TABLE #LC (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    DowntimeReasonTypeId BIGINT, ReasonTypeName NVARCHAR(100),
    DowntimeSourceCodeId BIGINT, SourceCodeName NVARCHAR(100),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #LC EXEC Oee.DowntimeReasonCode_List @OperationCategoryCode = N'DieCast', @IncludeDeprecated = 0;
DECLARE @CcDC   NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LC WHERE Code = N'TEST-DRC-001')  THEN N'1' ELSE N'0' END;
DECLARE @CcPW   NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LC WHERE Code = N'TEST-DRC-PW')   THEN N'1' ELSE N'0' END;
DECLARE @CcTrim NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LC WHERE Code = N'TEST-DRC-TRIM') THEN N'1' ELSE N'0' END;
DROP TABLE #LC;
EXEC test.Assert_IsEqual @TestName = N'DRC_List[ByCatCode]: die-cast code present',  @Expected = N'1', @Actual = @CcDC;
EXEC test.Assert_IsEqual @TestName = N'DRC_List[ByCatCode]: plant-wide code present', @Expected = N'1', @Actual = @CcPW;
EXEC test.Assert_IsEqual @TestName = N'DRC_List[ByCatCode]: trim code excluded',      @Expected = N'0', @Actual = @CcTrim;
GO

-- =============================================
-- Update with no changes succeeds (STUFF-on-empty NULL Description guard)
-- =============================================
DECLARE @Tid BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'TEST-DRC-001');
DECLARE @DieCatId BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @Snc BIT;
CREATE TABLE #UNC (Status BIT, Message NVARCHAR(500));
INSERT INTO #UNC EXEC Oee.DowntimeReasonCode_Update
    @Id = @Tid, @Description = N'Test downtime reason 001 (updated)', @OperationCategoryId = @DieCatId, @DowntimeReasonTypeId = 2, @IsExcused = 1, @AppUserId = 1;
SELECT @Snc = Status FROM #UNC; DROP TABLE #UNC;
DECLARE @Sncs NVARCHAR(1) = CAST(@Snc AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'DRC_Update[NoChange]: status is 1', @Expected = N'1', @Actual = @Sncs;
GO

-- =============================================
-- Cleanup: remove test rows so the suite is re-runnable
-- =============================================
DELETE FROM Oee.DowntimeReasonCode
WHERE Code IN (N'TEST-DRC-001', N'TEST-DRC-002', N'TST-DT-S8', N'TEST-DRC-PW', N'TEST-DRC-TRIM');
GO

EXEC test.EndTestFile;
GO
