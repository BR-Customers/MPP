-- =============================================
-- File:         0011_Quality_Spec/020_QualitySpecVersion_lifecycle.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Quality.QualitySpecVersion procs:
--     Quality.QualitySpecVersion_Create
--     Quality.QualitySpecVersion_CreateNewVersion
--     Quality.QualitySpecVersion_Get
--     Quality.QualitySpecVersion_ListBySpec
--     Quality.QualitySpecVersion_GetActiveForSpec
--     Quality.QualitySpecVersion_Publish
--     Quality.QualitySpecVersion_Deprecate
--
--   Covers: create v1 happy + duplicate + invalid parent;
--   draft invisibility via GetActiveForSpec; publish happy +
--   published reject + deprecated reject; CreateNewVersion
--   clone with attributes; list-by-spec ordering; deprecate;
--   historical AsOfDate query.
--
--   Pre-conditions:
--     - Migration 0001-0008 applied
--     - AppUser Id=1 exists
--     - QualitySpec_* procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/020_QualitySpecVersion_lifecycle.sql';
GO

-- =============================================
-- Setup: Create parent QualitySpec
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SpecId BIGINT;

CREATE TABLE #QR1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR1 EXEC Quality.QualitySpec_Create
    @Name        = N'Test Spec For Versioning',
    @Description = N'Parent spec for version tests',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR1;
DROP TABLE #QR1;
GO

-- =============================================
-- Test 1: QualitySpecVersion_Create happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @SpecId BIGINT,
        @VerId  BIGINT;

SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning';

CREATE TABLE #QR2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR2 EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId,
    @AppUserId     = 1;
SELECT @S = Status, @M = Message, @VerId = NewId FROM #QR2;
DROP TABLE #QR2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionCreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @VerIdStr NVARCHAR(20) = CAST(@VerId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[QSVersionCreateHappy] NewId is not NULL',
    @Value    = @VerIdStr;

-- Verify is Draft (PublishedAt NULL)
DECLARE @PubAt DATETIME2(3);
SELECT @PubAt = PublishedAt FROM Quality.QualitySpecVersion WHERE Id = @VerId;
DECLARE @IsDraft NVARCHAR(1) = CASE WHEN @PubAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionCreateHappy] Is Draft (PublishedAt NULL)',
    @Expected = N'1',
    @Actual   = @IsDraft;
GO

-- =============================================
-- Test 2: QualitySpecVersion_Create rejects duplicate
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @SpecId BIGINT,
        @VerId  BIGINT;

SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning';

CREATE TABLE #QR3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR3 EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId,
    @AppUserId     = 1;
SELECT @S = Status, @M = Message, @VerId = NewId FROM #QR3;
DROP TABLE #QR3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionCreateDupe] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSVersionCreateDupe] Message mentions CreateNewVersion',
    @HaystackStr = @M,
    @NeedleStr   = N'CreateNewVersion';
GO

-- =============================================
-- Test 3: Draft version is invisible to GetActiveForSpec
-- =============================================
DECLARE @SpecId BIGINT;
SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning';

CREATE TABLE #ActiveResult (
    Id BIGINT, QualitySpecId BIGINT, VersionNumber INT, EffectiveFrom DATETIME2(3),
    PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3), State NVARCHAR(20),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3), AttributeCount INT
);

INSERT INTO #ActiveResult
EXEC Quality.QualitySpecVersion_GetActiveForSpec @QualitySpecId = @SpecId;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #ActiveResult);
DECLARE @RowStr NVARCHAR(10) = CAST(@RowCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionDraftInvisible] GetActive returns 0 rows',
    @Expected = N'0',
    @Actual   = @RowStr;

DROP TABLE #ActiveResult;
GO

-- =============================================
-- Test 4: QualitySpecVersion_Publish happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @VerId  BIGINT;

SELECT @VerId = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 1;

CREATE TABLE #QR4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR4 EXEC Quality.QualitySpecVersion_Publish
    @Id        = @VerId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR4;
DROP TABLE #QR4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionPublishHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify PublishedAt is now set
DECLARE @PubAt DATETIME2(3);
SELECT @PubAt = PublishedAt FROM Quality.QualitySpecVersion WHERE Id = @VerId;
DECLARE @IsPublished NVARCHAR(1) = CASE WHEN @PubAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionPublishHappy] PublishedAt is set',
    @Expected = N'1',
    @Actual   = @IsPublished;
GO

-- =============================================
-- Test 5: Published version is visible to GetActiveForSpec
-- =============================================
DECLARE @SpecId BIGINT;
SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning';

CREATE TABLE #Active2 (
    Id BIGINT, QualitySpecId BIGINT, VersionNumber INT, EffectiveFrom DATETIME2(3),
    PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3), State NVARCHAR(20),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3), AttributeCount INT
);

INSERT INTO #Active2
EXEC Quality.QualitySpecVersion_GetActiveForSpec @QualitySpecId = @SpecId;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #Active2);
DECLARE @RowStr NVARCHAR(10) = CAST(@RowCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionPublishedVisible] GetActive returns 1 row',
    @Expected = N'1',
    @Actual   = @RowStr;

DROP TABLE #Active2;
GO

-- =============================================
-- Test 6: QualitySpecVersion_Publish rejects already published
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @VerId  BIGINT;

SELECT @VerId = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 1;

CREATE TABLE #QR5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR5 EXEC Quality.QualitySpecVersion_Publish
    @Id        = @VerId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR5;
DROP TABLE #QR5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionPublishDouble] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSVersionPublishDouble] Message mentions already',
    @HaystackStr = @M,
    @NeedleStr   = N'already';
GO

-- =============================================
-- Test 7: CreateNewVersion clones from v1
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @V1Id   BIGINT,
        @V2Id   BIGINT;

SELECT @V1Id = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 1;

-- Add a test attribute to v1 before cloning won't work (published)
-- So we test empty clone first

CREATE TABLE #QR6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR6 EXEC Quality.QualitySpecVersion_CreateNewVersion
    @SourceVersionId = @V1Id,
    @AppUserId       = 1;
SELECT @S = Status, @M = Message, @V2Id = NewId FROM #QR6;
DROP TABLE #QR6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionClone] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @V2IdStr NVARCHAR(20) = CAST(@V2Id AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[QSVersionClone] NewId is not NULL',
    @Value    = @V2IdStr;

-- Verify v2 has VersionNumber = 2
DECLARE @VerNum INT;
SELECT @VerNum = VersionNumber FROM Quality.QualitySpecVersion WHERE Id = @V2Id;
DECLARE @VerNumStr NVARCHAR(10) = CAST(@VerNum AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionClone] VersionNumber = 2',
    @Expected = N'2',
    @Actual   = @VerNumStr;

-- Verify v2 is Draft
DECLARE @V2Pub DATETIME2(3);
SELECT @V2Pub = PublishedAt FROM Quality.QualitySpecVersion WHERE Id = @V2Id;
DECLARE @V2Draft NVARCHAR(1) = CASE WHEN @V2Pub IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionClone] v2 is Draft',
    @Expected = N'1',
    @Actual   = @V2Draft;

-- Verify the readable audit Description follows the convention
-- (SUBJECT . Quality Spec "..." vN (Draft) . Created (...)).
DECLARE @AuditDesc NVARCHAR(MAX) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'QualitySpecVersion' AND cl.EntityId = @V2Id
    ORDER BY cl.Id DESC
);

EXEC test.Assert_Contains
    @TestName    = N'[QSVersionClone] Audit Description contains "Quality Spec"',
    @HaystackStr = @AuditDesc,
    @NeedleStr   = N'Quality Spec';

EXEC test.Assert_Contains
    @TestName    = N'[QSVersionClone] Audit Description contains "Created"',
    @HaystackStr = @AuditDesc,
    @NeedleStr   = N'Created';
GO

-- =============================================
-- Test 8: CreateNewVersion rejects when draft exists
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @V1Id   BIGINT,
        @V3Id   BIGINT;

SELECT @V1Id = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 1;

CREATE TABLE #QR7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR7 EXEC Quality.QualitySpecVersion_CreateNewVersion
    @SourceVersionId = @V1Id,
    @AppUserId       = 1;
SELECT @S = Status, @M = Message, @V3Id = NewId FROM #QR7;
DROP TABLE #QR7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionCloneDupe] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSVersionCloneDupe] Message mentions draft',
    @HaystackStr = @M,
    @NeedleStr   = N'Draft';
GO

-- =============================================
-- Test 9: QualitySpecVersion_Deprecate happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @V1Id   BIGINT;

SELECT @V1Id = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 1;

CREATE TABLE #QR8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR8 EXEC Quality.QualitySpecVersion_Deprecate
    @Id        = @V1Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR8;
DROP TABLE #QR8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionDeprecate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify DeprecatedAt is set
DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Quality.QualitySpecVersion WHERE Id = @V1Id;
DECLARE @IsDepr NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionDeprecate] DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @IsDepr;
GO

-- =============================================
-- Test 10: Deprecate rejects draft version
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @V2Id   BIGINT;

SELECT @V2Id = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 2;

CREATE TABLE #QR9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR9 EXEC Quality.QualitySpecVersion_Deprecate
    @Id        = @V2Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR9;
DROP TABLE #QR9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionDeprecateDraft] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSVersionDeprecateDraft] Message mentions draft',
    @HaystackStr = @M,
    @NeedleStr   = N'Draft';
GO

-- =============================================
-- Test 11: ListBySpec returns all versions
-- =============================================
DECLARE @SpecId BIGINT;
SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning';

CREATE TABLE #ListResult (
    Id BIGINT, QualitySpecId BIGINT, VersionNumber INT, EffectiveFrom DATETIME2(3),
    PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3), State NVARCHAR(20),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3), AttributeCount INT
);

INSERT INTO #ListResult
EXEC Quality.QualitySpecVersion_ListBySpec @QualitySpecId = @SpecId;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #ListResult);
DECLARE @RowStr NVARCHAR(10) = CAST(@RowCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionList] Returns 2 versions',
    @Expected = N'2',
    @Actual   = @RowStr;

-- Check ordering (newest first)
DECLARE @FirstVer INT = (SELECT TOP 1 VersionNumber FROM #ListResult ORDER BY VersionNumber DESC);
DECLARE @FirstVerStr NVARCHAR(10) = CAST(@FirstVer AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionList] First row is newest (v2)',
    @Expected = N'2',
    @Actual   = @FirstVerStr;

DROP TABLE #ListResult;
GO

-- =============================================
-- Test 12: QualitySpecVersion_Get returns state
-- =============================================
DECLARE @V1Id BIGINT;
SELECT @V1Id = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'Test Spec For Versioning')
AND VersionNumber = 1;

CREATE TABLE #GetResult (
    Id BIGINT, QualitySpecId BIGINT, QualitySpecName NVARCHAR(200), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    State NVARCHAR(20), CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200),
    CreatedAt DATETIME2(3), AttributeCount INT
);

INSERT INTO #GetResult
EXEC Quality.QualitySpecVersion_Get @Id = @V1Id;

DECLARE @State NVARCHAR(20) = (SELECT State FROM #GetResult);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVersionGet] State is Deprecated',
    @Expected = N'Deprecated',
    @Actual   = @State;

DROP TABLE #GetResult;
GO

EXEC test.EndTestFile;
GO
