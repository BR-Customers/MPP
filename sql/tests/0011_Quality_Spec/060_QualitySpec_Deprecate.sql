-- =============================================
-- File:         0011_Quality_Spec/060_QualitySpec_Deprecate.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-29
-- Description:
--   Tests for Quality.QualitySpec_Deprecate:
--     - happy path: header soft-delete + cascade-deprecate of child versions
--     - audit ConfigLog Description carries the Deprecated narrative
--
--   Pre-conditions:
--     - Migration 0001-0008 applied (QualitySpec.DeprecatedAt +
--       DeprecatedByUserId columns present)
--     - At least one Location.AppUser row exists
--     - QualitySpec_* / QualitySpecVersion_* procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/060_QualitySpec_Deprecate.sql';
GO

-- =============================================
-- Setup: create a spec + one version, then deprecate the spec
-- =============================================
DECLARE @User   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @SpecId BIGINT;
DECLARE @VerId  BIGINT;
DECLARE @S      BIT;
DECLARE @M      NVARCHAR(500);

CREATE TABLE #SpecRes (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SpecRes EXEC Quality.QualitySpec_Create
    @Name      = N'Retire Candidate Spec',
    @AppUserId = @User;
SELECT @SpecId = NewId FROM #SpecRes;
DROP TABLE #SpecRes;

CREATE TABLE #VerRes (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #VerRes EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId,
    @AppUserId     = @User;
SELECT @VerId = NewId FROM #VerRes;
DROP TABLE #VerRes;

CREATE TABLE #DepRes (Status BIT, Message NVARCHAR(500));
INSERT INTO #DepRes EXEC Quality.QualitySpec_Deprecate
    @QualitySpecId = @SpecId,
    @AppUserId     = @User;
SELECT @S = Status, @M = Message FROM #DepRes;
DROP TABLE #DepRes;

-- Test 1: Status is 1
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSDeprecate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Test 2: header DeprecatedAt is set
DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Quality.QualitySpec WHERE Id = @SpecId;
DECLARE @HdrDepr NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[QSDeprecate] Header DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @HdrDepr;

-- Test 3: no active child versions remain
DECLARE @ActiveVers INT =
    (SELECT COUNT(*) FROM Quality.QualitySpecVersion
     WHERE QualitySpecId = @SpecId AND DeprecatedAt IS NULL);
DECLARE @ActiveVersStr NVARCHAR(10) = CAST(@ActiveVers AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSDeprecate] No active child versions remain',
    @Expected = N'0',
    @Actual   = @ActiveVersStr;

-- Test 4: latest QualitySpec ConfigLog Description carries the Deprecated narrative
DECLARE @Desc NVARCHAR(1000) =
    (SELECT TOP 1 cl.Description
     FROM Audit.ConfigLog cl
     INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
     WHERE et.Code = N'QualitySpec' AND cl.EntityId = @SpecId
     ORDER BY cl.Id DESC);
EXEC test.Assert_Contains
    @TestName    = N'[QSDeprecate] Audit Description mentions Deprecated',
    @HaystackStr = @Desc,
    @NeedleStr   = N'Deprecated';
GO

EXEC test.EndTestFile;
GO
