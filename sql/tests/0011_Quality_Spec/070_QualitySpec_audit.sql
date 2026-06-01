-- =============================================
-- File:         0011_Quality_Spec/070_QualitySpec_audit.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-29
-- Description:
--   Audit-readability assertions for the Quality.QualitySpec* mutation
--   procs (audit-readability convention, Quality Spec Config Tool A6).
--
--   Verifies:
--     - Create spec -> create v1 -> publish v1 emits a QualitySpecVersion
--       ConfigLog Description containing the spec name and "Published",
--       and does NOT contain "deprecated v" (date-resolved lifecycle has
--       no auto-deprecate of prior Published versions).
--     - DiscardDraft of a fresh Draft returns Status=1, physically removes
--       the version row, and emits a Description containing "Discarded".
--
--   Pre-conditions:
--     - Migration 0001-0017 applied
--     - At least one Location.AppUser row exists
--     - Quality.QualitySpec* procs deployed (incl. _DiscardDraft)
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/070_QualitySpec_audit.sql';
GO

-- =============================================
-- Setup: resolve an AppUser; create a fixture spec + v1; publish v1
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @User   BIGINT,
        @SpecId BIGINT,
        @VerId  BIGINT;

SELECT @User = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);

CREATE TABLE #AC1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #AC1 EXEC Quality.QualitySpec_Create
    @Name        = N'Audit Fixture Spec',
    @Description = N'Audit-convention fixture',
    @AppUserId   = @User;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #AC1;
DROP TABLE #AC1;

CREATE TABLE #AC2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #AC2 EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId,
    @AppUserId     = @User;
SELECT @S = Status, @M = Message, @VerId = NewId FROM #AC2;
DROP TABLE #AC2;

CREATE TABLE #AC3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #AC3 EXEC Quality.QualitySpecVersion_Publish
    @Id        = @VerId,
    @AppUserId = @User;
SELECT @S = Status, @M = Message FROM #AC3;
DROP TABLE #AC3;
GO

-- =============================================
-- Test 1: Publish Description is readable, names the spec, says Published,
--         and does NOT carry an auto-deprecate "(deprecated vN)" suffix.
-- =============================================
DECLARE @VerId BIGINT;
SELECT @VerId = v.Id
FROM Quality.QualitySpecVersion v
INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId
WHERE s.Name = N'Audit Fixture Spec' AND v.VersionNumber = 1;

DECLARE @PubDesc NVARCHAR(MAX) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'QualitySpecVersion'
      AND cl.EntityId = @VerId
      AND cl.Description LIKE N'%Published%'
    ORDER BY cl.Id DESC
);

EXEC test.Assert_Contains
    @TestName    = N'[QSAuditPublish] Description contains "Published"',
    @HaystackStr = @PubDesc,
    @NeedleStr   = N'Published';

EXEC test.Assert_Contains
    @TestName    = N'[QSAuditPublish] Description names the spec',
    @HaystackStr = @PubDesc,
    @NeedleStr   = N'Audit Fixture Spec';

-- Must NOT contain an auto-deprecate suffix (date-resolved lifecycle).
DECLARE @NoDeprecate BIT = CASE WHEN @PubDesc LIKE N'%deprecated v%' THEN 0 ELSE 1 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[QSAuditPublish] Description has NO auto-deprecate suffix',
    @Condition = @NoDeprecate,
    @Detail    = N'Publish Description unexpectedly contained "deprecated v"';
GO

-- =============================================
-- Test 2: DiscardDraft of a fresh Draft -> Status=1, row gone, Description "Discarded"
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @User   BIGINT,
        @SpecId BIGINT,
        @SrcVerId BIGINT,
        @DraftId BIGINT;

SELECT @User   = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Audit Fixture Spec';
SELECT @SrcVerId = Id FROM Quality.QualitySpecVersion
WHERE QualitySpecId = @SpecId AND VersionNumber = 1;

-- Create a fresh draft (v2) to discard
CREATE TABLE #AD1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #AD1 EXEC Quality.QualitySpecVersion_CreateNewVersion
    @SourceVersionId = @SrcVerId,
    @AppUserId       = @User;
SELECT @DraftId = NewId FROM #AD1;
DROP TABLE #AD1;

-- Discard it
CREATE TABLE #AD2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #AD2 EXEC Quality.QualitySpecVersion_DiscardDraft
    @Id        = @DraftId,
    @AppUserId = @User;
SELECT @S = Status, @M = Message FROM #AD2;
DROP TABLE #AD2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSAuditDiscard] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Version row is gone (hard delete)
DECLARE @RowGone BIT = CASE WHEN NOT EXISTS
    (SELECT 1 FROM Quality.QualitySpecVersion WHERE Id = @DraftId) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[QSAuditDiscard] Discarded version row is gone',
    @Condition = @RowGone,
    @Detail    = N'QualitySpecVersion row still present after DiscardDraft';

-- Description contains "Discarded"
DECLARE @DiscDesc NVARCHAR(MAX) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'QualitySpecVersion' AND cl.EntityId = @DraftId
    ORDER BY cl.Id DESC
);

EXEC test.Assert_Contains
    @TestName    = N'[QSAuditDiscard] Description contains "Discarded"',
    @HaystackStr = @DiscDesc,
    @NeedleStr   = N'Discarded';
GO

-- =============================================
-- Test 3: DiscardDraft rejects a Published version (Status=0)
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @User   BIGINT,
        @VerId  BIGINT;

SELECT @User  = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
SELECT @VerId = v.Id
FROM Quality.QualitySpecVersion v
INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId
WHERE s.Name = N'Audit Fixture Spec' AND v.VersionNumber = 1;

CREATE TABLE #AD3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #AD3 EXEC Quality.QualitySpecVersion_DiscardDraft
    @Id        = @VerId,
    @AppUserId = @User;
SELECT @S = Status, @M = Message FROM #AD3;
DROP TABLE #AD3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSAuditDiscardPublished] Status is 0 (rejected)',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSAuditDiscardPublished] Message mentions published',
    @HaystackStr = @M,
    @NeedleStr   = N'published';
GO

EXEC test.EndTestFile;
GO
