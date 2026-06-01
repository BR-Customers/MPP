-- =============================================
-- File:         0011_Quality_Spec/040_DefectCode_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Quality.DefectCode procs:
--     Quality.DefectCode_List
--     Quality.DefectCode_Get
--     Quality.DefectCode_Create
--     Quality.DefectCode_Update
--     Quality.DefectCode_Deprecate
--
--   Covers: create happy + duplicate code + invalid area;
--   update happy + deprecated reject; list with/without
--   deprecated + filter by area; deprecate lifecycle.
--
--   Pre-conditions:
--     - Migration 0001-0008 applied
--     - AppUser Id=1 exists
--     - Location.Location seed with at least one Area
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/040_DefectCode_crud.sql';
GO

-- =============================================
-- Setup: Get or create test Area
-- =============================================
DECLARE @AreaId BIGINT;

-- Use existing Area from seed (Die Cast)
SELECT TOP 1 @AreaId = l.Id
FROM Location.Location l
JOIN Location.LocationTypeDefinition ltd ON l.LocationTypeDefinitionId = ltd.Id
JOIN Location.LocationType lt ON ltd.LocationTypeId = lt.Id
WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL;

IF @AreaId IS NULL
BEGIN
    RAISERROR('Test requires at least one Area location in seed data', 16, 1);
    RETURN;
END

-- Store AreaId for later tests
CREATE TABLE #TestContext (AreaId BIGINT);
INSERT INTO #TestContext VALUES (@AreaId);
GO

-- =============================================
-- Test 1: DefectCode_Create happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AreaId BIGINT,
        @NewId  BIGINT;

SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR1 EXEC Quality.DefectCode_Create
    @Code           = N'TEST-DEF-001',
    @Description    = N'Test defect code 001',
    @AreaLocationId = @AreaId,
    @IsExcused      = 0,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QR1;
DROP TABLE #QR1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectCreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[DefectCreateHappy] NewId is not NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 2: Create excused defect code
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AreaId BIGINT,
        @NewId  BIGINT;

SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR2 EXEC Quality.DefectCode_Create
    @Code           = N'TEST-DEF-002',
    @Description    = N'Test defect code 002 (excused)',
    @AreaLocationId = @AreaId,
    @IsExcused      = 1,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QR2;
DROP TABLE #QR2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectCreateExcused] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify IsExcused = 1
DECLARE @IsExc BIT;
SELECT @IsExc = IsExcused FROM Quality.DefectCode WHERE Id = @NewId;
DECLARE @IsExcStr NVARCHAR(1) = CAST(@IsExc AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectCreateExcused] IsExcused = 1',
    @Expected = N'1',
    @Actual   = @IsExcStr;
GO

-- =============================================
-- Test 3: Create third for filter test
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @AreaId BIGINT,
        @NewId  BIGINT;

SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR3 EXEC Quality.DefectCode_Create
    @Code           = N'TEST-DEF-003',
    @Description    = N'Test defect code 003',
    @AreaLocationId = @AreaId,
    @IsExcused      = 0,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QR3;
DROP TABLE #QR3;
GO

-- =============================================
-- Test 4: Create rejects duplicate code
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AreaId BIGINT,
        @NewId  BIGINT;

SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR4 EXEC Quality.DefectCode_Create
    @Code           = N'TEST-DEF-001',
    @Description    = N'Duplicate code',
    @AreaLocationId = @AreaId,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QR4;
DROP TABLE #QR4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectCreateDupe] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[DefectCreateDupe] Message mentions exists',
    @HaystackStr = @M,
    @NeedleStr   = N'exists';
GO

-- =============================================
-- Test 5: Create rejects invalid AreaLocationId
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @NewId  BIGINT;

CREATE TABLE #QR5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR5 EXEC Quality.DefectCode_Create
    @Code           = N'TEST-DEF-X',
    @Description    = N'Invalid area',
    @AreaLocationId = 999999,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QR5;
DROP TABLE #QR5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectCreateInvalidArea] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[DefectCreateInvalidArea] Message mentions AreaLocationId',
    @HaystackStr = @M,
    @NeedleStr   = N'AreaLocationId';
GO

-- =============================================
-- Test 6: DefectCode_Update happy path
-- =============================================
DECLARE @S        BIT,
        @M        NVARCHAR(500),
        @SStr     NVARCHAR(1),
        @DefectId BIGINT,
        @AreaId   BIGINT;

SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-001';
SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR6 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR6 EXEC Quality.DefectCode_Update
    @Id             = @DefectId,
    @Description    = N'Updated description',
    @AreaLocationId = @AreaId,
    @IsExcused      = 1,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message FROM #QR6;
DROP TABLE #QR6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectUpdateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify changes
DECLARE @NewDesc NVARCHAR(500), @NewExc BIT;
SELECT @NewDesc = Description, @NewExc = IsExcused FROM Quality.DefectCode WHERE Id = @DefectId;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectUpdateHappy] Description changed',
    @Expected = N'Updated description',
    @Actual   = @NewDesc;

DECLARE @ExcStr NVARCHAR(1) = CAST(@NewExc AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectUpdateHappy] IsExcused changed to 1',
    @Expected = N'1',
    @Actual   = @ExcStr;
GO

-- =============================================
-- Test 7: Update rejects not found
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AreaId BIGINT;

SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR7 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR7 EXEC Quality.DefectCode_Update
    @Id             = 999999,
    @Description    = N'Should fail',
    @AreaLocationId = @AreaId,
    @IsExcused      = 0,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message FROM #QR7;
DROP TABLE #QR7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectUpdateNotFound] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[DefectUpdateNotFound] Message mentions not found',
    @HaystackStr = @M,
    @NeedleStr   = N'not found';
GO

-- =============================================
-- Test 8: DefectCode_Get returns row
-- =============================================
DECLARE @DefectId BIGINT;
SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-001';

CREATE TABLE #GetResult (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    AreaLocationId BIGINT, AreaName NVARCHAR(200),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #GetResult
EXEC Quality.DefectCode_Get @Id = @DefectId;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #GetResult);
DECLARE @RowStr NVARCHAR(10) = CAST(@RowCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectGet] Returns 1 row',
    @Expected = N'1',
    @Actual   = @RowStr;

DROP TABLE #GetResult;
GO

-- =============================================
-- Test 9: DefectCode_List returns active codes
-- =============================================
CREATE TABLE #ListResult (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    AreaLocationId BIGINT, AreaName NVARCHAR(200),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #ListResult
EXEC Quality.DefectCode_List @IncludeDeprecated = 0;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #ListResult WHERE Code LIKE N'TEST-DEF-%');
DECLARE @HasRows NVARCHAR(1) = CASE WHEN @RowCount >= 3 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectList] Returns at least 3 test rows',
    @Expected = N'1',
    @Actual   = @HasRows;

DROP TABLE #ListResult;
GO

-- =============================================
-- Test 10: DefectCode_Deprecate happy path
-- =============================================
DECLARE @S        BIT,
        @M        NVARCHAR(500),
        @SStr     NVARCHAR(1),
        @DefectId BIGINT;

SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-003';

CREATE TABLE #QR8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR8 EXEC Quality.DefectCode_Deprecate
    @Id        = @DefectId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR8;
DROP TABLE #QR8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectDeprecate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify DeprecatedAt is set
DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Quality.DefectCode WHERE Id = @DefectId;
DECLARE @IsDepr NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectDeprecate] DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @IsDepr;
GO

-- =============================================
-- Test 11: Deprecated code excluded from default list
-- =============================================
CREATE TABLE #ActiveList (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    AreaLocationId BIGINT, AreaName NVARCHAR(200),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #ActiveList
EXEC Quality.DefectCode_List @IncludeDeprecated = 0;

DECLARE @HasDeprecated INT = (SELECT COUNT(*) FROM #ActiveList WHERE Code = N'TEST-DEF-003');
DECLARE @HasStr NVARCHAR(10) = CAST(@HasDeprecated AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectListExclude] Deprecated excluded',
    @Expected = N'0',
    @Actual   = @HasStr;

DROP TABLE #ActiveList;
GO

-- =============================================
-- Test 12: Include deprecated flag
-- =============================================
CREATE TABLE #AllList (
    Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    AreaLocationId BIGINT, AreaName NVARCHAR(200),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #AllList
EXEC Quality.DefectCode_List @IncludeDeprecated = 1;

DECLARE @HasDeprecated INT = (SELECT COUNT(*) FROM #AllList WHERE Code = N'TEST-DEF-003');
DECLARE @HasStr NVARCHAR(10) = CAST(@HasDeprecated AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectListInclude] Deprecated included',
    @Expected = N'1',
    @Actual   = @HasStr;

DROP TABLE #AllList;
GO

-- =============================================
-- Test 13: Update rejects deprecated
-- =============================================
DECLARE @S        BIT,
        @M        NVARCHAR(500),
        @SStr     NVARCHAR(1),
        @DefectId BIGINT,
        @AreaId   BIGINT;

SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-003';
SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QR9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR9 EXEC Quality.DefectCode_Update
    @Id             = @DefectId,
    @Description    = N'Should fail',
    @AreaLocationId = @AreaId,
    @IsExcused      = 0,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message FROM #QR9;
DROP TABLE #QR9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectUpdateDeprecated] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[DefectUpdateDeprecated] Message mentions deprecated',
    @HaystackStr = @M,
    @NeedleStr   = N'deprecated';
GO

-- =============================================
-- Test 14: Deprecate rejects already deprecated
-- =============================================
DECLARE @S        BIT,
        @M        NVARCHAR(500),
        @SStr     NVARCHAR(1),
        @DefectId BIGINT;

SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-003';

CREATE TABLE #QR10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR10 EXEC Quality.DefectCode_Deprecate
    @Id        = @DefectId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR10;
DROP TABLE #QR10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectDeprecateDupe] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[DefectDeprecateDupe] Message mentions already',
    @HaystackStr = @M,
    @NeedleStr   = N'already';
GO

-- =============================================
-- Slice 8 (audit-readability): Create Description carries
--   "Defect Code <Code> — <Name> (<AreaName>) · Created" and
--   NewValue JSON carries a resolved Area sub-object.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT, @AreaId BIGINT;
SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QS8a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QS8a EXEC Quality.DefectCode_Create
    @Code           = N'TST-DF-S8',
    @Description    = N'Blowhole',
    @AreaLocationId = @AreaId,
    @IsExcused      = 0,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QS8a;
DROP TABLE #QS8a;

DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DefectCode');

DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @NewId AND LogEntityTypeId = @EntTypeId
                               ORDER BY Id DESC);
DECLARE @CreatePattern NVARCHAR(300) =
    N'Defect Code TST-DF-S8 ' + NCHAR(8212) + N' Blowhole (%) '
    + Audit.ufn_MidDot() + N' Created';
DECLARE @CreateMatch NVARCHAR(1) = CASE WHEN @Desc LIKE @CreatePattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectS8Create] Description matches SUBJECT mid-dot Created',
    @Expected = N'1',
    @Actual   = @CreateMatch;

DECLARE @NewVal NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Audit.ConfigLog
                                 WHERE EntityId = @NewId AND LogEntityTypeId = @EntTypeId
                                 ORDER BY Id DESC);
DECLARE @CreateJson NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@NewVal, '$.Area.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectS8Create] NewValue has resolved Area.Name',
    @Expected = N'1',
    @Actual   = @CreateJson;
GO

-- =============================================
-- Slice 8: Update Description carries the Description field-diff
--   with both values quoted.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @DefectId BIGINT, @AreaId BIGINT;
SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TST-DF-S8';
SELECT @AreaId = AreaId FROM #TestContext;

CREATE TABLE #QS8b (Status BIT, Message NVARCHAR(500));
INSERT INTO #QS8b EXEC Quality.DefectCode_Update
    @Id             = @DefectId,
    @Description    = N'Surface blowhole',
    @AreaLocationId = @AreaId,
    @IsExcused      = 0,
    @AppUserId      = 1;
DROP TABLE #QS8b;

DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DefectCode');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @DefectId AND LogEntityTypeId = @EntTypeId
                               ORDER BY Id DESC);
DECLARE @UpdPattern NVARCHAR(400) =
    N'Defect Code TST-DF-S8 ' + Audit.ufn_MidDot()
    + N' Updated Description "Blowhole" ' + NCHAR(8594) + N' "Surface blowhole"';
DECLARE @UpdMatch NVARCHAR(1) = CASE WHEN @Desc LIKE @UpdPattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectS8Update] Description has quoted Description diff',
    @Expected = N'1',
    @Actual   = @UpdMatch;

DECLARE @OldVal NVARCHAR(MAX) = (SELECT TOP 1 OldValue FROM Audit.ConfigLog
                                 WHERE EntityId = @DefectId AND LogEntityTypeId = @EntTypeId
                                 ORDER BY Id DESC);
DECLARE @UpdJson NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@OldVal, '$.Area.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectS8Update] OldValue has resolved Area.Name',
    @Expected = N'1',
    @Actual   = @UpdJson;
GO

-- =============================================
-- Slice 8: Deprecate Description is verb-form; OldValue resolved.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @DefectId BIGINT;
SELECT @DefectId = Id FROM Quality.DefectCode WHERE Code = N'TST-DF-S8';

CREATE TABLE #QS8c (Status BIT, Message NVARCHAR(500));
INSERT INTO #QS8c EXEC Quality.DefectCode_Deprecate
    @Id = @DefectId, @AppUserId = 1;
DROP TABLE #QS8c;

DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DefectCode');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId = @DefectId AND LogEntityTypeId = @EntTypeId
                               ORDER BY Id DESC);
DECLARE @DepPattern NVARCHAR(200) =
    N'Defect Code TST-DF-S8 ' + Audit.ufn_MidDot() + N' Deprecated';
DECLARE @DepMatch NVARCHAR(1) = CASE WHEN @Desc LIKE @DepPattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectS8Deprecate] Description is "<Code> mid-dot Deprecated"',
    @Expected = N'1',
    @Actual   = @DepMatch;

DECLARE @OldVal NVARCHAR(MAX) = (SELECT TOP 1 OldValue FROM Audit.ConfigLog
                                 WHERE EntityId = @DefectId AND LogEntityTypeId = @EntTypeId
                                 ORDER BY Id DESC);
DECLARE @DepJson NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@OldVal, '$.Area.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DefectS8Deprecate] OldValue has resolved Area.Name',
    @Expected = N'1',
    @Actual   = @DepJson;
GO

-- Cleanup
DELETE FROM Quality.DefectCode WHERE Code = N'TST-DF-S8';
DROP TABLE #TestContext;
GO

EXEC test.EndTestFile;
GO
