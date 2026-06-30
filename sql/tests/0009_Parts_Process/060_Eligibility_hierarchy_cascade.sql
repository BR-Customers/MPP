-- =============================================
-- File:         0009_Parts_Process/060_Eligibility_hierarchy_cascade.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-30
-- Description:  Regression tests for the FDS-03-014 eligibility HIERARCHY CASCADE.
--               Engineering configures eligibility at the coarsest appropriate tier
--               (e.g. "5G1-C eligible across all of the DC1 Area" = one ItemLocation
--               row); a Cell-level resolution MUST surface items configured at any
--               ancestor tier (Cell -> WorkCenter -> Area -> Site). The walk is
--               encapsulated in Location.ufn_AncestorLocationIds and consumed by
--               Item_ListEligibleForLocation, ItemLocation_CheckEligibility, and the
--               Lot_Create / Lot_MoveToValidated / MachiningIn / TrimOut gates.
--
--               Read-only: asserts against seeded Area/WorkCenter-tier eligibility.
--               EXEC params are pre-assigned @variables per the SP-template convention.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/060_Eligibility_hierarchy_cascade.sql';
GO

-- =============================================
-- Test 1: Location.ufn_AncestorLocationIds returns the self+ancestor chain
-- =============================================
DECLARE @Cell BIGINT, @Area BIGINT;
SELECT TOP 1 @Cell = cell.Id, @Area = cell.ParentLocationId
FROM Location.Location cell
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = cell.LocationTypeDefinitionId
JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.Code = N'Cell' AND cell.DeprecatedAt IS NULL AND cell.ParentLocationId IS NOT NULL
ORDER BY cell.Id;

-- independent recursive walk up ParentLocationId, compared to the function
DECLARE @WalkCnt INT, @FnCnt INT, @Diff INT;
;WITH Chain AS (
    SELECT Id, ParentLocationId FROM Location.Location WHERE Id = @Cell
    UNION ALL
    SELECT p.Id, p.ParentLocationId FROM Location.Location p JOIN Chain c ON c.ParentLocationId = p.Id
)
SELECT @WalkCnt = COUNT(*) FROM Chain;
SELECT @FnCnt = COUNT(*) FROM Location.ufn_AncestorLocationIds(@Cell);
;WITH Chain AS (
    SELECT Id, ParentLocationId FROM Location.Location WHERE Id = @Cell
    UNION ALL
    SELECT p.Id, p.ParentLocationId FROM Location.Location p JOIN Chain c ON c.ParentLocationId = p.Id
)
SELECT @Diff =
    (SELECT COUNT(*) FROM (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Cell) EXCEPT SELECT Id FROM Chain) a)
  + (SELECT COUNT(*) FROM (SELECT Id FROM Chain EXCEPT SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Cell)) b);

DECLARE @WalkStr NVARCHAR(10) = CAST(@WalkCnt AS NVARCHAR(10));
DECLARE @FnStr   NVARCHAR(10) = CAST(@FnCnt AS NVARCHAR(10));
DECLARE @DiffStr NVARCHAR(10) = CAST(@Diff AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Casc] ufn count matches recursive ancestor walk', @Expected = @WalkStr, @Actual = @FnStr;
EXEC test.Assert_IsEqual @TestName = N'[Casc] ufn set identical to recursive walk',       @Expected = N'0',      @Actual = @DiffStr;

DECLARE @HasSelf NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(@Cell) WHERE LocationId = @Cell) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Casc] ufn includes the location itself', @Expected = N'1', @Actual = @HasSelf;

DECLARE @HasParent NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(@Cell) WHERE LocationId = @Area) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Casc] ufn includes the parent location', @Expected = N'1', @Actual = @HasParent;

DECLARE @NullCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Location.ufn_AncestorLocationIds(NULL)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Casc] ufn NULL input -> 0 rows', @Expected = N'0', @Actual = @NullCnt;

DECLARE @UnkCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Location.ufn_AncestorLocationIds(999999999)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Casc] ufn unknown id -> 0 rows', @Expected = N'0', @Actual = @UnkCnt;
GO

-- =============================================
-- Test 2: an item configured at an ANCESTOR tier is eligible at a descendant Cell,
--         shows up in that Cell's eligible-item list, and does NOT leak to a Cell
--         outside that ancestor's subtree.
-- =============================================
-- pick an (Item, AncestorLocation) Direct eligibility at a NON-Cell tier that has >=1 descendant Cell
DECLARE @Item BIGINT, @Anc BIGINT;
SELECT TOP 1 @Item = il.ItemId, @Anc = il.LocationId
FROM Parts.ItemLocation il
JOIN Location.Location loc ON loc.Id = il.LocationId
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = loc.LocationTypeDefinitionId
JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE il.DeprecatedAt IS NULL AND lt.Code <> N'Cell'
  AND EXISTS (
      SELECT 1 FROM Location.Location ch
      JOIN Location.LocationTypeDefinition cd ON cd.Id = ch.LocationTypeDefinitionId
      JOIN Location.LocationType clt ON clt.Id = cd.LocationTypeId
      WHERE clt.Code = N'Cell' AND ch.DeprecatedAt IS NULL
        AND EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(ch.Id) a WHERE a.LocationId = il.LocationId))
ORDER BY il.ItemId, il.LocationId;

-- a descendant Cell of @Anc
DECLARE @ChildCell BIGINT;
SELECT TOP 1 @ChildCell = ch.Id
FROM Location.Location ch
JOIN Location.LocationTypeDefinition cd ON cd.Id = ch.LocationTypeDefinitionId
JOIN Location.LocationType clt ON clt.Id = cd.LocationTypeId
WHERE clt.Code = N'Cell' AND ch.DeprecatedAt IS NULL
  AND EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(ch.Id) a WHERE a.LocationId = @Anc)
ORDER BY ch.Id;

-- precondition guard: the ancestor IS coarser than a Cell (sanity that we found fixtures)
DECLARE @FoundStr NVARCHAR(10) = CASE WHEN @Item IS NOT NULL AND @ChildCell IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Casc] seed has ancestor-tier eligibility with a descendant cell', @Expected = N'1', @Actual = @FoundStr;

-- CheckEligibility cascades to the child cell
CREATE TABLE #C (IsEligible BIT, Path NVARCHAR(20));
INSERT INTO #C EXEC Parts.ItemLocation_CheckEligibility @ItemId = @Item, @LocationId = @ChildCell;
DECLARE @CElig NVARCHAR(10) = (SELECT CAST(IsEligible AS NVARCHAR(10)) FROM #C);
DECLARE @CPath NVARCHAR(20) = (SELECT Path FROM #C);
DROP TABLE #C;
EXEC test.Assert_IsEqual @TestName = N'[Casc] ancestor-config item eligible at child cell', @Expected = N'1',      @Actual = @CElig;
EXEC test.Assert_IsEqual @TestName = N'[Casc] child-cell resolves Path=Direct',             @Expected = N'Direct', @Actual = @CPath;

-- Item_ListEligibleForLocation(childCell) surfaces the ancestor-eligible item
CREATE TABLE #L (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), MaxLotSize INT, MaxParts INT);
INSERT INTO #L EXEC Parts.Item_ListEligibleForLocation @LocationId = @ChildCell;
DECLARE @InList NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #L WHERE Id = @Item) THEN N'1' ELSE N'0' END;
DROP TABLE #L;
EXEC test.Assert_IsEqual @TestName = N'[Casc] child-cell eligible-list includes ancestor item', @Expected = N'1', @Actual = @InList;

-- isolation: a Cell whose entire ancestor chain carries no eligibility for @Item -> ineligible
DECLARE @OtherCell BIGINT;
SELECT TOP 1 @OtherCell = ch.Id
FROM Location.Location ch
JOIN Location.LocationTypeDefinition cd ON cd.Id = ch.LocationTypeDefinitionId
JOIN Location.LocationType clt ON clt.Id = cd.LocationTypeId
WHERE clt.Code = N'Cell' AND ch.DeprecatedAt IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM Parts.v_EffectiveItemLocation v
      WHERE v.ItemId = @Item
        AND EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(ch.Id) a WHERE a.LocationId = v.LocationId))
ORDER BY ch.Id;

CREATE TABLE #O (IsEligible BIT, Path NVARCHAR(20));
INSERT INTO #O EXEC Parts.ItemLocation_CheckEligibility @ItemId = @Item, @LocationId = @OtherCell;
DECLARE @OElig NVARCHAR(10) = (SELECT CAST(IsEligible AS NVARCHAR(10)) FROM #O);
DROP TABLE #O;
EXEC test.Assert_IsEqual @TestName = N'[Casc] eligibility does NOT leak to an unrelated cell', @Expected = N'0', @Actual = @OElig;
GO

-- =============================================
-- Test 3: every eligibility resolution point is wired to the cascade function
--         (guards against a proc being reverted to exact-location matching).
-- =============================================
DECLARE @NotWired INT = (
    SELECT COUNT(*) FROM (VALUES
        ('Parts.Item_ListEligibleForLocation'),
        ('Parts.ItemLocation_CheckEligibility'),
        ('Lots.Lot_Create'),
        ('Lots.Lot_MoveToValidated'),
        ('Workorder.MachiningIn_PickAndConsume'),
        ('Workorder.TrimOut_Record')) v(obj)
    WHERE OBJECT_DEFINITION(OBJECT_ID(v.obj)) NOT LIKE '%ufn_AncestorLocationIds%');
DECLARE @NotWiredStr NVARCHAR(10) = CAST(@NotWired AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Casc] all 6 eligibility call sites use ufn_AncestorLocationIds', @Expected = N'0', @Actual = @NotWiredStr;
GO

EXEC test.EndTestFile;
GO
