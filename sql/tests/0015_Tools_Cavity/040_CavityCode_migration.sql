-- =============================================
-- File:         0015_Tools_Cavity/040_CavityCode_migration.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-10
-- Description:
--   Migration 0076 -- Tools.ToolCavity.CavityCode.
--   Asserts the column exists NOT NULL as NVARCHAR(4), that the unique
--   index is re-scoped to (ToolId, ItemId, CavityCode), that CavityNumber
--   is relaxed to nullable (0077 drops it), and that per-part duplicate
--   codes are rejected while cross-part duplicates are allowed.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/040_CavityCode_migration.sql';
GO

-- =============================================
-- Test 1: CavityCode exists, NVARCHAR(4), NOT NULL
-- =============================================
DECLARE @IsNullable INT = (
    SELECT c.is_nullable FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'Tools.ToolCavity') AND c.name = N'CavityCode');
EXEC test.Assert_IsEqual
    @Actual = @IsNullable, @Expected = 0,
    @TestName = N'0076: CavityCode is NOT NULL';

DECLARE @MaxLen INT = (
    SELECT c.max_length / 2 FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'Tools.ToolCavity') AND c.name = N'CavityCode');
EXEC test.Assert_IsEqual
    @Actual = @MaxLen, @Expected = 4,
    @TestName = N'0076: CavityCode is NVARCHAR(4)';
GO

-- =============================================
-- Test 2: unique index is scoped to (ToolId, ItemId, CavityCode)
-- =============================================
DECLARE @NewIdx INT = (
    SELECT COUNT(*) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Tools.ToolCavity')
      AND name = N'UQ_ToolCavity_ActiveToolItemCode');
EXEC test.Assert_IsEqual
    @Actual = @NewIdx, @Expected = 1,
    @TestName = N'0076: UQ_ToolCavity_ActiveToolItemCode exists';

DECLARE @OldIdx INT = (
    SELECT COUNT(*) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Tools.ToolCavity')
      AND name = N'UQ_ToolCavity_ActiveToolCavity');
EXEC test.Assert_IsEqual
    @Actual = @OldIdx, @Expected = 0,
    @TestName = N'0076: old die-wide unique index is gone';

DECLARE @IdxCols INT = (
    SELECT COUNT(*) FROM sys.index_columns ic
    INNER JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.name = N'UQ_ToolCavity_ActiveToolItemCode'
      AND c.name IN (N'ToolId', N'ItemId', N'CavityCode'));
EXEC test.Assert_IsEqual
    @Actual = @IdxCols, @Expected = 3,
    @TestName = N'0076: unique index keys on ToolId + ItemId + CavityCode';
GO

-- =============================================
-- Test 3: both legacy CavityNumber columns are gone
-- =============================================
DECLARE @TcNum INT = (
    SELECT COUNT(*) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'CavityNumber');
EXEC test.Assert_IsEqual
    @Actual = @TcNum, @Expected = 0,
    @TestName = N'0076: Tools.ToolCavity.CavityNumber dropped';

DECLARE @LotNum INT = (
    SELECT COUNT(*) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'CavityNumber');
EXEC test.Assert_IsEqual
    @Actual = @LotNum, @Expected = 0,
    @TestName = N'0076: Lots.Lot.CavityNumber dropped (D2 retired)';
GO

-- =============================================
-- Test 4: cavity 'a' may exist once per PART, not twice on one part.
--         Exercised at the INDEX level -- proc-level rules are 020.
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveTId BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @ActiveCId BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

CREATE TABLE #T (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId, @Code = N'CODE-TEST-DIE', @Name = N'Alpha Code Test Die',
    @StatusCodeId = @ActiveTId, @AppUserId = 1;
DECLARE @ToolId BIGINT = (SELECT NewId FROM #T);
DROP TABLE #T;

DECLARE @ItemA BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL);
DECLARE @ItemB BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id > @ItemA);

INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
VALUES (@ToolId, N'a', @ItemA, @ActiveCId, 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
VALUES (@ToolId, N'a', @ItemB, @ActiveCId, 1);

DECLARE @CrossPart INT = (
    SELECT COUNT(*) FROM Tools.ToolCavity
    WHERE ToolId = @ToolId AND CavityCode = N'a' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @Actual = @CrossPart, @Expected = 2,
    @TestName = N'0076: cavity a allowed on two different parts of one tool';

DECLARE @Dup INT = 0;
BEGIN TRY
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
    VALUES (@ToolId, N'a', @ItemA, @ActiveCId, 1);
END TRY
BEGIN CATCH
    SET @Dup = 1;
END CATCH
EXEC test.Assert_IsEqual
    @Actual = @Dup, @Expected = 1,
    @TestName = N'0076: duplicate cavity a on the SAME part is rejected';

-- Case-insensitive collation: 'A' collides with 'a'
DECLARE @Case INT = 0;
BEGIN TRY
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
    VALUES (@ToolId, N'A', @ItemA, @ActiveCId, 1);
END TRY
BEGIN CATCH
    SET @Case = 1;
END CATCH
EXEC test.Assert_IsEqual
    @Actual = @Case, @Expected = 1,
    @TestName = N'0076: uppercase A collides with a (CI collation)';

DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;
DELETE FROM Tools.Tool WHERE Id = @ToolId;
GO

-- =============================================
-- Test 5: DELIBERATELY ABSENT -- the backfill cannot be asserted here.
--
-- Run-Tests resets with -SkipDemoSeed, so the versioned migrations run
-- against a database with ZERO Tools.ToolCavity rows. The backfill in
-- migration 0076 letters rows that already EXIST when it runs, so in this
-- database it letters nothing and there is nothing to assert. Every cavity
-- visible here was created by a test file AFTER the migration, through
-- ToolCavity_Create / ToolCavity_SaveAll -- which is proc behaviour, and is
-- covered by 010 / 020 / 030.
--
-- An earlier revision asserted "6MA-B letters as 4 parts x 3 cavities" and
-- failed for exactly this reason (Expected 4, Actual 0); its sibling
-- assertion passed only because it ran over an empty set, which is worse --
-- a test that cannot fail. Both removed rather than gated, because a
-- silently-skipped assertion reads as coverage it does not provide.
--
-- Where the backfill IS verified:
--   * migration 0076 step 3 -- ABORTS if a family die has an unmapped
--     cavity, the case that mis-letters peers (prod DMO124 cavity 7)
--   * migration 0076 step 5 -- PRINTS where a derived letter disagrees with
--     the letter operators already typed at the end of Description
--   * the pre-flight dry-run in the plan's Task 1, run against the real
--     data (MPP_MES_Dev reproduces 6MA-A / 6MA-B correctly; prod is a gate)
-- =============================================

EXEC test.PrintSummary;
GO
