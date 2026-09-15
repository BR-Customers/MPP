-- =============================================
-- File:         0026_Tools_CellMount/030_ListEligibleForCell.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-14
-- Description:
--   Tools.Tool_ListEligibleForCell -- the part-driven die shortlist behind the
--   plant-floor Die Mount popup.
--
--     1. FALLBACK: a press with no machine-tier Parts.ItemLocation row returns
--        EVERY compatible unmounted die, all rows IsEligible = 0. Eligibility
--        shortens a list; it never refuses one.
--     2. SHORTLIST: once the press carries a machine-tier row, only dies
--        cutting a part mapped there come back, all rows IsEligible = 1 --
--        never a mix, because the fallback is decided once with a COUNT(*).
--     3. A die mounted elsewhere is excluded in BOTH branches.
--     4. Unknown / deprecated cell -> empty rowset.
--
--   The test cell is chosen dynamically as a DieCastMachine with NO
--   ItemLocation rows at all, which is what makes assertion 1 deterministic
--   against a seeded plant.
--
--   Self-isolating: ELG- fixtures, own cleanup (including the ItemLocation row
--   it adds).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_Tools_CellMount/030_ListEligibleForCell.sql';
GO

-- ---- setup ----
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'ELG-%');
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'ELG-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'ELG-%';

DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType       WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @DcmDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');

-- A press with NO part-to-machine mapping and nothing mounted.
DECLARE @Cell BIGINT = (SELECT TOP 1 m.Id FROM Location.Location m
    WHERE m.LocationTypeDefinitionId = @DcmDef
      AND m.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.LocationId = m.Id AND il.DeprecatedAt IS NULL)
      AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                      WHERE ta.CellLocationId = m.Id AND ta.ReleasedAt IS NULL)
    ORDER BY m.Id DESC);

-- A second press to park the mounted-elsewhere die on.
DECLARE @OtherCell BIGINT = (SELECT TOP 1 m.Id FROM Location.Location m
    WHERE m.LocationTypeDefinitionId = @DcmDef
      AND m.DeprecatedAt IS NULL
      AND m.Id <> @Cell
      AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                      WHERE ta.CellLocationId = m.Id AND ta.ReleasedAt IS NULL)
    ORDER BY m.Id DESC);

DECLARE @Item1 BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item2 BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @Item1 ORDER BY Id);

DECLARE @T1 BIGINT, @T2 BIGINT, @T3 BIGINT;

CREATE TABLE #t (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #t EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'ELG-DIE-1', @Name = N'Eligible Die 1',
    @StatusCodeId = @Active, @AppUserId = 1;
SET @T1 = (SELECT NewId FROM #t);
DELETE FROM #t;
INSERT INTO #t EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'ELG-DIE-2', @Name = N'Eligible Die 2',
    @StatusCodeId = @Active, @AppUserId = 1;
SET @T2 = (SELECT NewId FROM #t);
DELETE FROM #t;
INSERT INTO #t EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'ELG-DIE-3', @Name = N'Eligible Die 3 (mounted)',
    @StatusCodeId = @Active, @AppUserId = 1;
SET @T3 = (SELECT NewId FROM #t);
DROP TABLE #t;

CREATE TABLE #c (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c EXEC Tools.ToolCavity_Create
    @ToolId = @T1, @CavityCode = N'a', @Description = N'ELG 1a', @ItemId = @Item1, @AppUserId = 1;
DELETE FROM #c;
INSERT INTO #c EXEC Tools.ToolCavity_Create
    @ToolId = @T2, @CavityCode = N'a', @Description = N'ELG 2a', @ItemId = @Item2, @AppUserId = 1;
DELETE FROM #c;
INSERT INTO #c EXEC Tools.ToolCavity_Create
    @ToolId = @T3, @CavityCode = N'a', @Description = N'ELG 3a', @ItemId = @Item1, @AppUserId = 1;
DROP TABLE #c;

CREATE TABLE #a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #a EXEC Tools.ToolAssignment_Assign
    @ToolId = @T3, @CellLocationId = @OtherCell, @Notes = N'ELG parked', @AppUserId = 1;
DROP TABLE #a;

CREATE TABLE #ctx (Cell BIGINT, OtherCell BIGINT, Item1 BIGINT, Item2 BIGINT);
INSERT INTO #ctx (Cell, OtherCell, Item1, Item2) VALUES (@Cell, @OtherCell, @Item1, @Item2);
GO

-- =============================================
-- Test 1: FALLBACK -- no machine-tier mapping on this press
-- =============================================
DECLARE @Cell BIGINT = (SELECT Cell FROM #ctx);

CREATE TABLE #e (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), IsEligible BIT);
INSERT INTO #e EXEC Tools.Tool_ListEligibleForCell @CellLocationId = @Cell;

DECLARE @has1 INT = (SELECT COUNT(*) FROM #e WHERE Code = N'ELG-DIE-1');
EXEC test.Assert_RowCount
    @TestName = N'[Eligible fallback] unmapped die 1 is offered',
    @ExpectedCount = 1, @ActualCount = @has1;

DECLARE @has2 INT = (SELECT COUNT(*) FROM #e WHERE Code = N'ELG-DIE-2');
EXEC test.Assert_RowCount
    @TestName = N'[Eligible fallback] unmapped die 2 is offered',
    @ExpectedCount = 1, @ActualCount = @has2;

DECLARE @anyFlagged INT = (SELECT COUNT(*) FROM #e WHERE IsEligible = 1);
EXEC test.Assert_RowCount
    @TestName = N'[Eligible fallback] every row is IsEligible = 0',
    @ExpectedCount = 0, @ActualCount = @anyFlagged;

DECLARE @mounted INT = (SELECT COUNT(*) FROM #e WHERE Code = N'ELG-DIE-3');
EXEC test.Assert_RowCount
    @TestName = N'[Eligible fallback] a die mounted elsewhere is excluded',
    @ExpectedCount = 0, @ActualCount = @mounted;
DROP TABLE #e;
GO

-- =============================================
-- Test 2: SHORTLIST -- map Item1 to this press at the machine tier
-- =============================================
DECLARE @Cell  BIGINT = (SELECT Cell  FROM #ctx);
DECLARE @Item1 BIGINT = (SELECT Item1 FROM #ctx);

INSERT INTO Parts.ItemLocation (ItemId, LocationId) VALUES (@Item1, @Cell);

CREATE TABLE #e (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), IsEligible BIT);
INSERT INTO #e EXEC Tools.Tool_ListEligibleForCell @CellLocationId = @Cell;

DECLARE @flag1 NVARCHAR(1) = (SELECT CAST(IsEligible AS NVARCHAR(1)) FROM #e WHERE Code = N'ELG-DIE-1');
EXEC test.Assert_IsEqual
    @TestName = N'[Eligible shortlist] mapped die 1 returns IsEligible = 1',
    @Expected = N'1', @Actual = @flag1;

DECLARE @has2 INT = (SELECT COUNT(*) FROM #e WHERE Code = N'ELG-DIE-2');
EXEC test.Assert_RowCount
    @TestName = N'[Eligible shortlist] unmapped die 2 is filtered out',
    @ExpectedCount = 0, @ActualCount = @has2;

DECLARE @anyUnflagged INT = (SELECT COUNT(*) FROM #e WHERE IsEligible = 0);
EXEC test.Assert_RowCount
    @TestName = N'[Eligible shortlist] no mixed flags -- every row IsEligible = 1',
    @ExpectedCount = 0, @ActualCount = @anyUnflagged;

DECLARE @mounted INT = (SELECT COUNT(*) FROM #e WHERE Code = N'ELG-DIE-3');
EXEC test.Assert_RowCount
    @TestName = N'[Eligible shortlist] a die mounted elsewhere is still excluded',
    @ExpectedCount = 0, @ActualCount = @mounted;
DROP TABLE #e;
GO

-- =============================================
-- Test 3: unknown cell -> empty rowset (no invented 404)
-- =============================================
CREATE TABLE #e (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), IsEligible BIT);
INSERT INTO #e EXEC Tools.Tool_ListEligibleForCell @CellLocationId = 999999999;
DECLARE @rc INT = (SELECT COUNT(*) FROM #e);
EXEC test.Assert_RowCount
    @TestName = N'[Eligible unknown cell] empty rowset',
    @ExpectedCount = 0, @ActualCount = @rc;
DROP TABLE #e;
GO

-- ---- teardown ----
-- The ItemLocation row Test 2 added is real configuration data on a real
-- press; remove it or the next run's cell-with-no-mapping lookup skips this
-- press and Test 1 silently stops testing the fallback.
DELETE FROM Parts.ItemLocation
WHERE LocationId = (SELECT Cell FROM #ctx)
  AND ItemId     = (SELECT Item1 FROM #ctx);

DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'ELG-%');
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'ELG-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'ELG-%';
DROP TABLE #ctx;
GO

EXEC test.PrintSummary;
GO
