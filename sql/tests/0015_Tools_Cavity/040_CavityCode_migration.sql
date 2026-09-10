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
-- Test 5: the backfill lettered every existing row, and did so per part.
--         Seeded family dies (6MA-A, 6MA-B) must start each part at 'a'.
--         6MA-B is the 12-cavity / 4-part die from prod.
-- =============================================
-- Scoped to the SEEDED tools only. An unscoped count would also see rows
-- that other test files create through the procs, which is whole-DB state,
-- not a property of the migration.
DECLARE @BadGroups INT = (
    SELECT COUNT(*) FROM (
        SELECT tc.ToolId, ISNULL(tc.ItemId, -1) AS ItemGrp
        FROM Tools.ToolCavity tc
        INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
        WHERE tc.DeprecatedAt IS NULL
          AND t.Code IN (N'6MA-A', N'6MA-B', N'59B', N'5G0', N'5G0-F-A', N'6NA')
        GROUP BY tc.ToolId, ISNULL(tc.ItemId, -1)
        HAVING MIN(tc.CavityCode) <> N'a'
    ) g);
EXEC test.Assert_IsEqual
    @Actual = @BadGroups, @Expected = 0,
    @TestName = N'0076: every seeded (Tool, Item) group starts at a';

-- 6MA-B is the family die: 12 cavities, 4 parts, so exactly 4 groups of a,b,c
DECLARE @FamilyGroups INT = (
    SELECT COUNT(*) FROM (
        SELECT tc.ItemId FROM Tools.ToolCavity tc
        INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
        WHERE t.Code = N'6MA-B' AND tc.DeprecatedAt IS NULL
        GROUP BY tc.ItemId HAVING COUNT(*) = 3
    ) g);
EXEC test.Assert_IsEqual
    @Actual = @FamilyGroups, @Expected = 4,
    @TestName = N'0076: 6MA-B letters as 4 parts x 3 cavities';
GO

EXEC test.PrintSummary;
GO
