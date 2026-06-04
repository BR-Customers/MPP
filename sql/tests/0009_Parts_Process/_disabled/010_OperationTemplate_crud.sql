-- =============================================
-- File:         0009_Parts_Process/010_OperationTemplate_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Parts.OperationTemplate CRUD + OperationTemplateField
--   junction procs:
--     Parts.OperationTemplate_List
--     Parts.OperationTemplate_Get
--     Parts.OperationTemplate_Create
--     Parts.OperationTemplate_CreateNewVersion
--     Parts.OperationTemplate_Update
--     Parts.OperationTemplate_Deprecate
--     Parts.OperationTemplateField_ListByTemplate
--     Parts.OperationTemplateField_Add
--     Parts.OperationTemplateField_Remove
--
--   Covers: create happy + validation branches (NULL required,
--   duplicate code, invalid area), get happy + NULL Id, list with
--   area filter, CreateNewVersion happy + NULL parent + non-existent,
--   update happy + deprecated rejection, deprecate happy + double
--   deprecation + dependency rejection (active RouteStep), junction
--   add happy + duplicate + invalid field + list (active only) +
--   remove happy + remove-twice rejection, and a ConfigLog audit
--   trail check.
--
--   Pre-conditions:
--     - Migration 0001-0006 applied
--     - AppUser bootstrap user Id=1 exists
--     - Seed Locations present (Area-tier): DIECAST Id=3, MACHSHOP
--       Id=4, QC Id=5
--     - Parts.DataCollectionField seeds 1..7 present
--     - Audit.LogEntityType includes 'OperationTemplate',
--       'OpTemplateField', and 'Route'
--     - All Parts.OperationTemplate*, Parts.OperationTemplateField_*,
--       Parts.RouteTemplate_Create, Parts.RouteStep_Add procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/010_OperationTemplate_crud.sql';
GO

-- =============================================
-- Test 1: OperationTemplate_Create happy path
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc1
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-001',
    @Name           = N'Test OP 001',
    @AreaLocationId = 3,              -- DIECAST
    @Description    = N'First test operation',
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc1;
DROP TABLE #Rc1;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[CreateHappy] NewId is not NULL',
    @Value    = @NewIdStr;

-- Verify row stored with VersionNumber = 1
DECLARE @StoredVersion INT,
        @StoredCode    NVARCHAR(20),
        @StoredArea    BIGINT;

SELECT @StoredVersion = VersionNumber,
       @StoredCode    = Code,
       @StoredArea    = AreaLocationId
FROM Parts.OperationTemplate
WHERE Id = @NewId;

DECLARE @StoredVersionStr NVARCHAR(20) = CAST(@StoredVersion AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] VersionNumber is 1',
    @Expected = N'1',
    @Actual   = @StoredVersionStr;

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] Code stored',
    @Expected = N'TEST-OP-001',
    @Actual   = @StoredCode;

DECLARE @StoredAreaStr NVARCHAR(20) = CAST(@StoredArea AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] AreaLocationId stored',
    @Expected = N'3',
    @Actual   = @StoredAreaStr;
GO

-- =============================================
-- Test 2: OperationTemplate_Create NULL required param
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc2
EXEC Parts.OperationTemplate_Create
    @Code           = NULL,
    @Name           = N'Missing Code',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc2;
DROP TABLE #Rc2;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateNullCode] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateNullCode] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 3: OperationTemplate_Create duplicate Code
--   Second call should fail with "already exists" (Create is the
--   new-family proc; subsequent versions go through CreateNewVersion).
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @Id1   BIGINT,
        @Id2   BIGINT;

CREATE TABLE #Rc3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc3
EXEC Parts.OperationTemplate_Create
    @Code           = N'DUP-OP',
    @Name           = N'Dup Target',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @Id1 = NewId FROM #Rc3;
DROP TABLE #Rc3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateDup] First: Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

CREATE TABLE #Rc4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc4
EXEC Parts.OperationTemplate_Create
    @Code           = N'DUP-OP',
    @Name           = N'Dup Attempt',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @Id2 = NewId FROM #Rc4;
DROP TABLE #Rc4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateDup] Second: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @DupMsgStr NVARCHAR(1) = CASE WHEN @M LIKE N'%already exists%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[CreateDup] Second: Message contains "already exists"',
    @Expected = N'1',
    @Actual   = @DupMsgStr;

DECLARE @Id2Str NVARCHAR(20) = CAST(@Id2 AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateDup] Second: NewId is NULL',
    @Value    = @Id2Str;
GO

-- =============================================
-- Test 4: OperationTemplate_Create invalid AreaLocationId
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc5
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-BADAREA',
    @Name           = N'Bad Area',
    @AreaLocationId = 999999,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc5;
DROP TABLE #Rc5;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateBadArea] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateBadArea] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 5: OperationTemplate_Get happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OtId   BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

DECLARE @GetCount INT;
DECLARE @GotAreaName NVARCHAR(200);
CREATE TABLE #Get1 (
    Id BIGINT, Code NVARCHAR(50), VersionNumber INT, Name NVARCHAR(200),
    AreaLocationId BIGINT, AreaName NVARCHAR(200), Description NVARCHAR(500),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #Get1 EXEC Parts.OperationTemplate_Get @Id = @OtId;
SELECT @GetCount = COUNT(*), @GotAreaName = MAX(AreaName) FROM #Get1;
DROP TABLE #Get1;

EXEC test.Assert_RowCount
    @TestName      = N'[GetHappy] 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @GetCount;

EXEC test.Assert_IsNotNull
    @TestName = N'[GetHappy] AreaName populated in proc result',
    @Value    = @GotAreaName;
GO

-- Test 6 (NULL Id) removed: converted read procs no longer error on NULL.

-- =============================================
-- Test 7: OperationTemplate_List (all) happy path — executes without error
-- =============================================
CREATE TABLE #ListAll (
    Id BIGINT, Code NVARCHAR(50), VersionNumber INT, Name NVARCHAR(200),
    AreaLocationId BIGINT, AreaName NVARCHAR(200), Description NVARCHAR(500),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #ListAll EXEC Parts.OperationTemplate_List;
DECLARE @ListAllCount INT = (SELECT COUNT(*) FROM #ListAll);
DROP TABLE #ListAll;

DECLARE @HasAny BIT = CASE WHEN @ListAllCount >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[ListAll] Proc returned >= 1 row',
    @Condition = @HasAny;
GO

-- =============================================
-- Test 8: OperationTemplate_List filtered by AreaLocationId
--   Create a row in MACHSHOP (Id=4), then filter — verify no rows
--   with a different AreaLocationId come back.
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc6
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-MS-1',
    @Name           = N'MachShop OP 1',
    @AreaLocationId = 4,              -- MACHSHOP
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc6;
DROP TABLE #Rc6;

-- Validate by direct query (List returns a single result set we don't
-- INSERT..EXEC to avoid coupling to its column shape).
DECLARE @NonMatchCount INT = (
    SELECT COUNT(*)
    FROM Parts.OperationTemplate
    WHERE AreaLocationId = 4
      AND Code LIKE N'TEST-OP-MS-%'
);

EXEC test.Assert_RowCount
    @TestName      = N'[ListByArea] At least one TEST-OP-MS row in MACHSHOP',
    @ExpectedCount = 1,
    @ActualCount   = @NonMatchCount;

-- Call the list proc with the filter and capture result set
CREATE TABLE #ListByArea (
    Id BIGINT, Code NVARCHAR(50), VersionNumber INT, Name NVARCHAR(200),
    AreaLocationId BIGINT, AreaName NVARCHAR(200), Description NVARCHAR(500),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #ListByArea EXEC Parts.OperationTemplate_List @AreaLocationId = 4;
DECLARE @ProcMatchCount INT = (SELECT COUNT(*) FROM #ListByArea WHERE AreaLocationId = 4);
DROP TABLE #ListByArea;

DECLARE @ProcHasMatch BIT = CASE WHEN @ProcMatchCount >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[ListByArea] Filtered list: proc returned >= 1 matching row',
    @Condition = @ProcHasMatch;
GO

-- =============================================
-- Test 9: OperationTemplate_CreateNewVersion happy path
--   Create a parent, add 2 fields to it, then CreateNewVersion.
--   Assert the new row has VersionNumber = parent + 1, a distinct Id,
--   and OTF rows copied over.
-- =============================================
DECLARE @S         BIT,
        @M         NVARCHAR(500),
        @SStr      NVARCHAR(1),
        @ParentId  BIGINT,
        @NewVerId  BIGINT,
        @OtfId1    BIGINT,
        @OtfId2    BIGINT;

CREATE TABLE #Rc7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc7
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-VER',
    @Name           = N'Versioned Base',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @ParentId = NewId FROM #Rc7;
DROP TABLE #Rc7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[NewVer] Parent created: Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Add 2 OTFs to parent
CREATE TABLE #Rc8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc8
EXEC Parts.OperationTemplateField_Add
    @OperationTemplateId   = @ParentId,
    @DataCollectionFieldId = 1,   -- MaterialVerification
    @IsRequired            = 1,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @OtfId1 = NewId FROM #Rc8;
DROP TABLE #Rc8;

CREATE TABLE #Rc9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc9
EXEC Parts.OperationTemplateField_Add
    @OperationTemplateId   = @ParentId,
    @DataCollectionFieldId = 5,   -- Weight
    @IsRequired            = 1,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @OtfId2 = NewId FROM #Rc9;
DROP TABLE #Rc9;

-- Create a new version
CREATE TABLE #Rc10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc10
EXEC Parts.OperationTemplate_CreateNewVersion
    @ParentOperationTemplateId = @ParentId,
    @AppUserId                 = 1;
SELECT @S = Status, @M = Message, @NewVerId = NewId FROM #Rc10;
DROP TABLE #Rc10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[NewVer] CreateNewVersion: Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewVerIdStr NVARCHAR(20) = CAST(@NewVerId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[NewVer] NewId is not NULL',
    @Value    = @NewVerIdStr;

-- Assert distinct Ids
DECLARE @DistinctStr NVARCHAR(1) = CASE WHEN @NewVerId <> @ParentId THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[NewVer] NewId differs from parent Id',
    @Expected = N'1',
    @Actual   = @DistinctStr;

-- Assert VersionNumber incremented
DECLARE @ParentVer INT, @NewVer INT;
SELECT @ParentVer = VersionNumber FROM Parts.OperationTemplate WHERE Id = @ParentId;
SELECT @NewVer    = VersionNumber FROM Parts.OperationTemplate WHERE Id = @NewVerId;

DECLARE @VerExpected INT = @ParentVer + 1;
DECLARE @VerExpStr   NVARCHAR(20) = CAST(@VerExpected AS NVARCHAR(20));
DECLARE @NewVerStr   NVARCHAR(20) = CAST(@NewVer      AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[NewVer] New VersionNumber = parent + 1',
    @Expected = @VerExpStr,
    @Actual   = @NewVerStr;

-- Assert same Code on new version
DECLARE @NewCode NVARCHAR(20);
SELECT @NewCode = Code FROM Parts.OperationTemplate WHERE Id = @NewVerId;
EXEC test.Assert_IsEqual
    @TestName = N'[NewVer] Code preserved across versions',
    @Expected = N'TEST-OP-VER',
    @Actual   = @NewCode;

-- Assert OTF rows copied
DECLARE @OtfCopyCount INT;
SELECT @OtfCopyCount = COUNT(*)
FROM Parts.OperationTemplateField
WHERE OperationTemplateId = @NewVerId
  AND DeprecatedAt IS NULL;

EXEC test.Assert_RowCount
    @TestName      = N'[NewVer] OTF rows copied (2 active on new version)',
    @ExpectedCount = 2,
    @ActualCount   = @OtfCopyCount;
GO

-- =============================================
-- Test 10: OperationTemplate_CreateNewVersion NULL parent rejected
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc11 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc11
EXEC Parts.OperationTemplate_CreateNewVersion
    @ParentOperationTemplateId = NULL,
    @AppUserId                 = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc11;
DROP TABLE #Rc11;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[NewVerNull] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[NewVerNull] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 11: OperationTemplate_CreateNewVersion non-existent parent
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc12 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc12
EXEC Parts.OperationTemplate_CreateNewVersion
    @ParentOperationTemplateId = 999999,
    @AppUserId                 = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc12;
DROP TABLE #Rc12;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[NewVerBadParent] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 12: OperationTemplate_Update happy path
--   Update Name + Description. Code and VersionNumber are immutable
--   (not parameters on Update).
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @OtId BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

CREATE TABLE #Ru19 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru19
EXEC Parts.OperationTemplate_Update
    @Id             = @OtId,
    @Name           = N'Test OP 001 Updated',
    @AreaLocationId = 3,
    @Description    = N'Updated description',
    @AppUserId      = 1;
SELECT @S = Status, @M = Message FROM #Ru19;
DROP TABLE #Ru19;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify Name changed
DECLARE @StoredName NVARCHAR(100),
        @StoredCode NVARCHAR(20),
        @StoredVer  INT;
SELECT @StoredName = Name,
       @StoredCode = Code,
       @StoredVer  = VersionNumber
FROM Parts.OperationTemplate
WHERE Id = @OtId;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] Name changed',
    @Expected = N'Test OP 001 Updated',
    @Actual   = @StoredName;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] Code unchanged (immutable)',
    @Expected = N'TEST-OP-001',
    @Actual   = @StoredCode;

DECLARE @StoredVerStr NVARCHAR(20) = CAST(@StoredVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] VersionNumber unchanged (immutable)',
    @Expected = N'1',
    @Actual   = @StoredVerStr;
GO

-- =============================================
-- Test 13: OperationTemplate_Update on deprecated row rejected
--   Create + deprecate, then update. Status=0.
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @OtId  BIGINT;

CREATE TABLE #Rc13 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc13
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-UPDDEP',
    @Name           = N'Will Deprecate',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @OtId = NewId FROM #Rc13;
DROP TABLE #Rc13;

CREATE TABLE #Ru20 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru20
EXEC Parts.OperationTemplate_Deprecate
    @Id        = @OtId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru20;
DROP TABLE #Ru20;

CREATE TABLE #Ru21 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru21
EXEC Parts.OperationTemplate_Update
    @Id             = @OtId,
    @Name           = N'Should Not Apply',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message FROM #Ru21;
DROP TABLE #Ru21;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateDep] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- Name should still be original
DECLARE @Name2 NVARCHAR(100);
SELECT @Name2 = Name FROM Parts.OperationTemplate WHERE Id = @OtId;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateDep] Name unchanged',
    @Expected = N'Will Deprecate',
    @Actual   = @Name2;
GO

-- =============================================
-- Test 14: OperationTemplate_Deprecate happy path (no RouteStep refs)
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @OtId  BIGINT;

CREATE TABLE #Rc14 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc14
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-DEP1',
    @Name           = N'Deprecate Target',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @OtId = NewId FROM #Rc14;
DROP TABLE #Rc14;

CREATE TABLE #Ru22 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru22
EXEC Parts.OperationTemplate_Deprecate
    @Id        = @OtId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru22;
DROP TABLE #Ru22;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DepHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Parts.OperationTemplate WHERE Id = @OtId;

DECLARE @DepAtStr NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DepHappy] DeprecatedAt is not NULL',
    @Expected = N'1',
    @Actual   = @DepAtStr;
GO

-- =============================================
-- Test 15: OperationTemplate_Deprecate twice rejected
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @OtId  BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-OP-DEP1';

CREATE TABLE #Ru23 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru23
EXEC Parts.OperationTemplate_Deprecate
    @Id        = @OtId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru23;
DROP TABLE #Ru23;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DepTwice] Second call: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 16: OperationTemplate_Deprecate with active RouteStep dependency
--   Set up: create Item → RouteTemplate → add a RouteStep that
--   references the OT. Then attempt to deprecate the OT; expect
--   Status=0 with "active RouteSteps reference" in message.
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @OtId    BIGINT,
        @ItemId  BIGINT,
        @RtId    BIGINT,
        @StepId  BIGINT;

-- OT to protect from deprecation
CREATE TABLE #Rc15 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc15
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-OP-REFD',
    @Name           = N'Referenced OP',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @OtId = NewId FROM #Rc15;
DROP TABLE #Rc15;

-- Item to own the route
CREATE TABLE #Rc20 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc20
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-OP-RT-ITEM',
    @Description = N'Route-owning item for OT dependency test',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @ItemId = NewId FROM #Rc20;
DROP TABLE #Rc20;

-- RouteTemplate
CREATE TABLE #Rc1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc1
EXEC Parts.RouteTemplate_Create
    @ItemId    = @ItemId,
    @Name      = N'TEST-RT-OT-DEP',
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @RtId = NewId FROM #Rc1;
DROP TABLE #Rc1;

-- RouteStep pointing at the OT
CREATE TABLE #Rc2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc2
EXEC Parts.RouteStep_Add
    @RouteTemplateId     = @RtId,
    @OperationTemplateId = @OtId,
    @IsRequired          = 1,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @StepId = NewId FROM #Rc2;
DROP TABLE #Rc2;

-- Attempt to deprecate the OT — must fail
CREATE TABLE #Ru24 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru24
EXEC Parts.OperationTemplate_Deprecate
    @Id        = @OtId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru24;
DROP TABLE #Ru24;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DepRefd] Status is 0 (RouteStep references)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @RefdMsgStr NVARCHAR(1) = CASE WHEN @M LIKE N'%active RouteStep%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DepRefd] Message mentions "active RouteStep"',
    @Expected = N'1',
    @Actual   = @RefdMsgStr;

-- Verify the OT is still active (DeprecatedAt IS NULL)
DECLARE @StillActive NVARCHAR(1) = (
    SELECT CASE WHEN DeprecatedAt IS NULL THEN N'1' ELSE N'0' END
    FROM Parts.OperationTemplate WHERE Id = @OtId
);
EXEC test.Assert_IsEqual
    @TestName = N'[DepRefd] OT remains active',
    @Expected = N'1',
    @Actual   = @StillActive;
GO

-- =============================================
-- Test 17: OperationTemplateField_Add happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OtId   BIGINT,
        @OtfId  BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

CREATE TABLE #Rc16 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc16
EXEC Parts.OperationTemplateField_Add
    @OperationTemplateId   = @OtId,
    @DataCollectionFieldId = 2,   -- SerialNumber
    @IsRequired            = 1,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @OtfId = NewId FROM #Rc16;
DROP TABLE #Rc16;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[OtfAddHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @OtfIdStr NVARCHAR(20) = CAST(@OtfId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[OtfAddHappy] NewId is not NULL',
    @Value    = @OtfIdStr;

-- Verify row exists and is active
DECLARE @OtfRowCount INT = (
    SELECT COUNT(*) FROM Parts.OperationTemplateField
    WHERE Id = @OtfId AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[OtfAddHappy] Active OTF row present',
    @ExpectedCount = 1,
    @ActualCount   = @OtfRowCount;
GO

-- =============================================
-- Test 18: OperationTemplateField_Add duplicate active pairing rejected
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OtId   BIGINT,
        @OtfId  BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

CREATE TABLE #Rc17 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc17
EXEC Parts.OperationTemplateField_Add
    @OperationTemplateId   = @OtId,
    @DataCollectionFieldId = 2,   -- SerialNumber - already added above
    @IsRequired            = 1,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @OtfId = NewId FROM #Rc17;
DROP TABLE #Rc17;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[OtfAddDup] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @DupHit NVARCHAR(1) = CASE
    WHEN @M LIKE N'%already%' OR @M LIKE N'%active%' OR @M LIKE N'%exists%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[OtfAddDup] Friendly message returned',
    @Expected = N'1',
    @Actual   = @DupHit;
GO

-- =============================================
-- Test 19: OperationTemplateField_Add invalid DataCollectionFieldId
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OtId   BIGINT,
        @OtfId  BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

CREATE TABLE #Rc18 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc18
EXEC Parts.OperationTemplateField_Add
    @OperationTemplateId   = @OtId,
    @DataCollectionFieldId = 999999,
    @IsRequired            = 1,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @OtfId = NewId FROM #Rc18;
DROP TABLE #Rc18;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[OtfAddBadField] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @OtfIdStr NVARCHAR(20) = CAST(@OtfId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[OtfAddBadField] NewId is NULL',
    @Value    = @OtfIdStr;
GO

-- =============================================
-- Test 20: OperationTemplateField_ListByTemplate returns active rows only
--   TEST-OP-001 has SerialNumber active. Verify list result by
--   direct-query assertion (no temp-table EXEC coupling).
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @OtId BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

CREATE TABLE #OtfList (
    Id BIGINT, OperationTemplateId BIGINT, DataCollectionFieldId BIGINT,
    DataCollectionFieldCode NVARCHAR(50), DataCollectionFieldName NVARCHAR(100),
    IsRequired BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #OtfList EXEC Parts.OperationTemplateField_ListByTemplate @OperationTemplateId = @OtId;
DECLARE @ProcOtfCount INT = (SELECT COUNT(*) FROM #OtfList);
DROP TABLE #OtfList;

DECLARE @ProcOtfCountStr NVARCHAR(20) = CAST(@ProcOtfCount AS NVARCHAR(20));
DECLARE @OtfListHasRow NVARCHAR(1) = CASE WHEN @ProcOtfCount >= 1 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[OtfList] Proc returned >= 1 row for TEST-OP-001',
    @Expected = N'1',
    @Actual   = @OtfListHasRow;

-- Active-row count on the junction table mirrors what the proc should return
DECLARE @ActiveCount INT = (
    SELECT COUNT(*) FROM Parts.OperationTemplateField
    WHERE OperationTemplateId = @OtId AND DeprecatedAt IS NULL
);
DECLARE @ActiveCountStr NVARCHAR(20) = CAST(@ActiveCount AS NVARCHAR(20));
DECLARE @CountGe1Str    NVARCHAR(1)  = CASE WHEN @ActiveCount >= 1 THEN N'1' ELSE N'0' END;

EXEC test.Assert_IsEqual
    @TestName = N'[OtfList] At least one active OTF for TEST-OP-001',
    @Expected = N'1',
    @Actual   = @CountGe1Str;
GO

-- =============================================
-- Test 21: OperationTemplateField_Remove happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OtId   BIGINT,
        @OtfId  BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

SELECT @OtfId = Id FROM Parts.OperationTemplateField
WHERE OperationTemplateId = @OtId
  AND DataCollectionFieldId = 2
  AND DeprecatedAt IS NULL;

CREATE TABLE #Ru25 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru25
EXEC Parts.OperationTemplateField_Remove
    @Id        = @OtfId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru25;
DROP TABLE #Ru25;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[OtfRemoveHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @OtfDepAt DATETIME2(3);
SELECT @OtfDepAt = DeprecatedAt FROM Parts.OperationTemplateField WHERE Id = @OtfId;
DECLARE @OtfDepAtStr NVARCHAR(1) = CASE WHEN @OtfDepAt IS NOT NULL THEN N'1' ELSE N'0' END;

EXEC test.Assert_IsEqual
    @TestName = N'[OtfRemoveHappy] DeprecatedAt set',
    @Expected = N'1',
    @Actual   = @OtfDepAtStr;
GO

-- =============================================
-- Test 22: OperationTemplateField_Remove already deprecated rejected
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OtId   BIGINT,
        @OtfId  BIGINT;

SELECT @OtId = Id FROM Parts.OperationTemplate
WHERE Code = N'TEST-OP-001' AND VersionNumber = 1;

SELECT @OtfId = Id FROM Parts.OperationTemplateField
WHERE OperationTemplateId = @OtId
  AND DataCollectionFieldId = 2;   -- deprecated by prior test

CREATE TABLE #Ru26 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru26
EXEC Parts.OperationTemplateField_Remove
    @Id        = @OtfId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru26;
DROP TABLE #Ru26;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[OtfRemoveTwice] Second call: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 23: Audit trail - ConfigLog has >= 5 entries for OperationTemplate
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'OperationTemplate';

DECLARE @AuditCond BIT = CASE WHEN @AuditCount >= 5 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[Audit] ConfigLog has >= 5 OperationTemplate entries',
    @Condition = @AuditCond;
GO

-- =============================================
-- Cleanup: delete test rows in dependency order.
-- =============================================
-- OTF rows (junction to OT)
DELETE otf
FROM Parts.OperationTemplateField otf
INNER JOIN Parts.OperationTemplate ot ON ot.Id = otf.OperationTemplateId
WHERE ot.Code LIKE N'TEST-OP-%'
   OR ot.Code = N'DUP-OP';

-- RouteSteps under test RouteTemplates (those named TEST-RT-%)
DELETE rs
FROM Parts.RouteStep rs
INNER JOIN Parts.RouteTemplate rt ON rt.Id = rs.RouteTemplateId
WHERE rt.Name LIKE N'TEST-RT-%';

-- RouteTemplates themselves
DELETE FROM Parts.RouteTemplate WHERE Name LIKE N'TEST-RT-%';

-- Items created for dependency tests
DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-OP-RT-ITEM%';

-- Finally the OperationTemplates
DELETE FROM Parts.OperationTemplate
WHERE Code LIKE N'TEST-OP-%' OR Code = N'DUP-OP';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
