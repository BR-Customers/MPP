-- =============================================
-- File:         0016_Tools_Assignment/020_Release_open_basket_guard.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-14
-- Description:
--   Tools.ToolAssignment_Release v1.1 -- the open-basket guard.
--
--     1. Rejected while the die holds an Open LOT on a live cavity.
--     2. Succeeds once that LOT closes.
--     3. The two pre-existing rejections still fire, in order.
--     4. THE GUARD DOES NOT COUNT WHAT THE SCREEN CANNOT SHOW. An Open LOT on
--        a DEPRECATED cavity, and one with a NULL ToolCavityId, must NOT
--        block. Both are invisible to Lots.Lot_GetOpenByTool (cavity-driven,
--        filters tc.DeprecatedAt IS NULL), so blocking on them would freeze a
--        die with nothing on the operator's screen to act on. A test that
--        asserts a block here has the polarity backwards -- read
--        the spec's 5.4.1 before "fixing" it.
--
--   LOT fixtures are INSERTed directly rather than minted through
--   Lots.Lot_Create: the guard is about LotStatus + ToolCavityId and nothing
--   else, and a direct row keeps the test clear of route / BOM validation it
--   does not care about.
--
--   Self-isolating: RBG- fixtures, own cleanup. Cells resolved dynamically.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0016_Tools_Assignment/020_Release_open_basket_guard.sql';
GO

-- ---- setup ----
DELETE FROM Lots.LotGenealogyClosure
WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RBG-%')
   OR AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RBG-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'RBG-%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'RBG-%');
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'RBG-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'RBG-%';

DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType       WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #t (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #t EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'RBG-DIE-1', @Name = N'Release Guard Die 1',
    @StatusCodeId = @Active, @AppUserId = 1;
DECLARE @ToolId BIGINT = (SELECT NewId FROM #t);
DROP TABLE #t;

CREATE TABLE #c1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c1 EXEC Tools.ToolCavity_Create
    @ToolId = @ToolId, @CavityCode = N'a', @Description = N'RBG cavity a', @AppUserId = 1;
DECLARE @CavA BIGINT = (SELECT NewId FROM #c1);
DROP TABLE #c1;

CREATE TABLE #c2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c2 EXEC Tools.ToolCavity_Create
    @ToolId = @ToolId, @CavityCode = N'b', @Description = N'RBG cavity b', @AppUserId = 1;
DECLARE @CavB BIGINT = (SELECT NewId FROM #c2);
DROP TABLE #c2;

DECLARE @DcmDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @Cell BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = @DcmDef AND DeprecatedAt IS NULL ORDER BY Id DESC);
DELETE FROM Tools.ToolAssignment WHERE CellLocationId = @Cell AND ReleasedAt IS NULL;

CREATE TABLE #ctx (ToolId BIGINT, CavA BIGINT, CavB BIGINT, Cell BIGINT,
                   ItemId BIGINT, OpenId BIGINT, ClosedId BIGINT);
INSERT INTO #ctx (ToolId, CavA, CavB, Cell, ItemId, OpenId, ClosedId)
VALUES (@ToolId, @CavA, @CavB, @Cell,
        (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id),
        (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open'),
        (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed'));
GO

-- =============================================
-- Test 1: Release REJECTED while an Open LOT sits on a live cavity
-- =============================================
DECLARE @ToolId BIGINT = (SELECT ToolId FROM #ctx);
DECLARE @Cell   BIGINT = (SELECT Cell   FROM #ctx);

CREATE TABLE #a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #a EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolId, @CellLocationId = @Cell, @Notes = N'RBG mount', @AppUserId = 1;
DROP TABLE #a;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      ToolId, ToolCavityId, CurrentLocationId, CreatedByUserId)
SELECT N'RBG-LOT-A', c.ItemId,
       (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
       c.OpenId, 42, c.ToolId, c.CavA, c.Cell, 1
FROM #ctx c;

CREATE TABLE #r (Status BIT, Message NVARCHAR(500));
INSERT INTO #r EXEC Tools.ToolAssignment_Release
    @ToolId = @ToolId, @AppUserId = 1, @Notes = N'RBG try';
DECLARE @s NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #r);
DECLARE @m NVARCHAR(500) = (SELECT Message FROM #r);
DROP TABLE #r;

EXEC test.Assert_IsEqual
    @TestName = N'[Release guard] rejected while a basket is open',
    @Expected = N'0', @Actual = @s;

EXEC test.Assert_Contains
    @TestName = N'[Release guard] message names the count',
    @HaystackStr = @m, @NeedleStr = N'1 open basket';

DECLARE @stillMounted INT = (SELECT COUNT(*) FROM Tools.ToolAssignment
                             WHERE ToolId = @ToolId AND ReleasedAt IS NULL);
EXEC test.Assert_RowCount
    @TestName = N'[Release guard] assignment still active after rejection',
    @ExpectedCount = 1, @ActualCount = @stillMounted;
GO

-- =============================================
-- Test 2: Release SUCCEEDS once the basket closes
-- =============================================
DECLARE @ToolId BIGINT = (SELECT ToolId FROM #ctx);

UPDATE Lots.Lot SET LotStatusId = (SELECT ClosedId FROM #ctx) WHERE LotName = N'RBG-LOT-A';

CREATE TABLE #r (Status BIT, Message NVARCHAR(500));
INSERT INTO #r EXEC Tools.ToolAssignment_Release
    @ToolId = @ToolId, @AppUserId = 1, @Notes = N'RBG ok';
DECLARE @s NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #r);
DROP TABLE #r;

EXEC test.Assert_IsEqual
    @TestName = N'[Release guard] succeeds once the basket closes',
    @Expected = N'1', @Actual = @s;
GO

-- =============================================
-- Test 3: the two pre-existing rejections still fire
--   The new check must not have reordered them -- a no-active-assignment
--   release must still say so rather than reporting a basket count.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT ToolId FROM #ctx);

CREATE TABLE #r (Status BIT, Message NVARCHAR(500));
INSERT INTO #r EXEC Tools.ToolAssignment_Release @ToolId = @ToolId, @AppUserId = 1;
DECLARE @s NVARCHAR(1)   = (SELECT CAST(Status AS NVARCHAR(1)) FROM #r);
DECLARE @m NVARCHAR(500) = (SELECT Message FROM #r);
DROP TABLE #r;

EXEC test.Assert_IsEqual
    @TestName = N'[Release guard] no active assignment still rejects',
    @Expected = N'0', @Actual = @s;
EXEC test.Assert_Contains
    @TestName = N'[Release guard] no-active-assignment message unchanged',
    @HaystackStr = @m, @NeedleStr = N'No active assignment';

CREATE TABLE #r2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #r2 EXEC Tools.ToolAssignment_Release @ToolId = NULL, @AppUserId = 1;
DECLARE @s2 NVARCHAR(1)   = (SELECT CAST(Status AS NVARCHAR(1)) FROM #r2);
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM #r2);
DROP TABLE #r2;

EXEC test.Assert_IsEqual
    @TestName = N'[Release guard] missing parameter still rejects',
    @Expected = N'0', @Actual = @s2;
EXEC test.Assert_Contains
    @TestName = N'[Release guard] missing-parameter message unchanged',
    @HaystackStr = @m2, @NeedleStr = N'Required parameter missing';
GO

-- =============================================
-- Test 4a: an Open LOT on a DEPRECATED cavity does NOT block
--   The cavity is deprecated by direct UPDATE because ToolCavity_Deprecate
--   v1.1 now refuses exactly this -- the row shape under test is HISTORICAL
--   data created before that guard existed, which is the only way it can
--   still arise.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT ToolId FROM #ctx);
DECLARE @Cell   BIGINT = (SELECT Cell   FROM #ctx);
DECLARE @CavB   BIGINT = (SELECT CavB   FROM #ctx);

CREATE TABLE #a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #a EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolId, @CellLocationId = @Cell, @Notes = N'RBG remount', @AppUserId = 1;
DROP TABLE #a;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      ToolId, ToolCavityId, CurrentLocationId, CreatedByUserId)
SELECT N'RBG-LOT-B', c.ItemId,
       (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
       c.OpenId, 7, c.ToolId, c.CavB, c.Cell, 1
FROM #ctx c;

UPDATE Tools.ToolCavity SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @CavB;

CREATE TABLE #r (Status BIT, Message NVARCHAR(500));
INSERT INTO #r EXEC Tools.ToolAssignment_Release
    @ToolId = @ToolId, @AppUserId = 1, @Notes = N'RBG deprecated-cavity';
DECLARE @s NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #r);
DROP TABLE #r;

EXEC test.Assert_IsEqual
    @TestName = N'[Release guard] basket on a DEPRECATED cavity does not block',
    @Expected = N'1', @Actual = @s;
GO

-- =============================================
-- Test 4b: an Open LOT with a NULL ToolCavityId does NOT block
--   Lots.Lot.ToolCavityId is nullable and Lot_GetOpenByTool joins on it, so
--   such a basket is invisible on the Die Cast screen too.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT ToolId FROM #ctx);
DECLARE @Cell   BIGINT = (SELECT Cell   FROM #ctx);

CREATE TABLE #a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #a EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolId, @CellLocationId = @Cell, @Notes = N'RBG remount 2', @AppUserId = 1;
DROP TABLE #a;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      ToolId, ToolCavityId, CurrentLocationId, CreatedByUserId)
SELECT N'RBG-LOT-C', c.ItemId,
       (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
       c.OpenId, 9, c.ToolId, NULL, c.Cell, 1
FROM #ctx c;

CREATE TABLE #r (Status BIT, Message NVARCHAR(500));
INSERT INTO #r EXEC Tools.ToolAssignment_Release
    @ToolId = @ToolId, @AppUserId = 1, @Notes = N'RBG null-cavity';
DECLARE @s NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #r);
DROP TABLE #r;

EXEC test.Assert_IsEqual
    @TestName = N'[Release guard] basket with a NULL cavity does not block',
    @Expected = N'1', @Actual = @s;
GO

-- ---- teardown ----
DELETE FROM Lots.LotGenealogyClosure
WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RBG-%')
   OR AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RBG-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'RBG-%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'RBG-%');
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'RBG-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'RBG-%';
DROP TABLE #ctx;
GO

EXEC test.PrintSummary;
GO
