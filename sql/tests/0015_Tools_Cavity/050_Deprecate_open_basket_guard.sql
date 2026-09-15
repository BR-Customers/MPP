-- =============================================
-- File:         0015_Tools_Cavity/050_Deprecate_open_basket_guard.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-14
-- Description:
--   Tools.ToolCavity_Deprecate v1.1 -- the open-basket guard.
--
--   Deprecating a cavity that holds an Open LOT used to make that basket
--   INVISIBLE on the Die Cast screen (Lots.Lot_GetOpenByTool is cavity-driven
--   and filters tc.DeprecatedAt IS NULL) while it stayed Open on the die.
--   Tools.ToolAssignment_Release v1.1 made that latent hole load-bearing, so
--   it is closed at the source.
--
--     1. Rejected while the cavity holds an Open LOT.
--     2. Succeeds once that LOT closes.
--     3. The two pre-existing rejections still fire, in order.
--
--   Self-isolating: CDG- fixtures, own cleanup.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/050_Deprecate_open_basket_guard.sql';
GO

-- ---- setup ----
DELETE FROM Lots.LotGenealogyClosure
WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CDG-%')
   OR AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CDG-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'CDG-%';
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CDG-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CDG-%';

DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType       WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #t (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #t EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'CDG-DIE-1', @Name = N'Cavity Deprecate Guard Die',
    @StatusCodeId = @Active, @AppUserId = 1;
DECLARE @ToolId BIGINT = (SELECT NewId FROM #t);
DROP TABLE #t;

CREATE TABLE #c (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c EXEC Tools.ToolCavity_Create
    @ToolId = @ToolId, @CavityCode = N'a', @Description = N'CDG cavity a', @AppUserId = 1;
DECLARE @CavA BIGINT = (SELECT NewId FROM #c);
DROP TABLE #c;

DECLARE @DcmDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');

CREATE TABLE #ctx (ToolId BIGINT, CavA BIGINT, Cell BIGINT, ItemId BIGINT,
                   OpenId BIGINT, ClosedId BIGINT);
INSERT INTO #ctx (ToolId, CavA, Cell, ItemId, OpenId, ClosedId)
VALUES (@ToolId, @CavA,
        (SELECT TOP 1 Id FROM Location.Location
         WHERE LocationTypeDefinitionId = @DcmDef AND DeprecatedAt IS NULL ORDER BY Id DESC),
        (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id),
        (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open'),
        (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed'));

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      ToolId, ToolCavityId, CurrentLocationId, CreatedByUserId)
SELECT N'CDG-LOT-A', c.ItemId,
       (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
       c.OpenId, 15, c.ToolId, c.CavA, c.Cell, 1
FROM #ctx c;
GO

-- =============================================
-- Test 1: Deprecate REJECTED while the cavity holds an Open LOT
-- =============================================
DECLARE @CavA BIGINT = (SELECT CavA FROM #ctx);

CREATE TABLE #d (Status BIT, Message NVARCHAR(500));
INSERT INTO #d EXEC Tools.ToolCavity_Deprecate @Id = @CavA, @AppUserId = 1;
DECLARE @s NVARCHAR(1)   = (SELECT CAST(Status AS NVARCHAR(1)) FROM #d);
DECLARE @m NVARCHAR(500) = (SELECT Message FROM #d);
DROP TABLE #d;

EXEC test.Assert_IsEqual
    @TestName = N'[Cavity deprecate guard] rejected while a basket is open',
    @Expected = N'0', @Actual = @s;
EXEC test.Assert_Contains
    @TestName = N'[Cavity deprecate guard] message names the cause',
    @HaystackStr = @m, @NeedleStr = N'open basket';

DECLARE @stillActive INT = (SELECT COUNT(*) FROM Tools.ToolCavity
                            WHERE Id = @CavA AND DeprecatedAt IS NULL);
EXEC test.Assert_RowCount
    @TestName = N'[Cavity deprecate guard] cavity still active after rejection',
    @ExpectedCount = 1, @ActualCount = @stillActive;
GO

-- =============================================
-- Test 2: Deprecate SUCCEEDS once the basket closes
-- =============================================
DECLARE @CavA BIGINT = (SELECT CavA FROM #ctx);

UPDATE Lots.Lot SET LotStatusId = (SELECT ClosedId FROM #ctx) WHERE LotName = N'CDG-LOT-A';

CREATE TABLE #d (Status BIT, Message NVARCHAR(500));
INSERT INTO #d EXEC Tools.ToolCavity_Deprecate @Id = @CavA, @AppUserId = 1;
DECLARE @s NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #d);
DROP TABLE #d;

EXEC test.Assert_IsEqual
    @TestName = N'[Cavity deprecate guard] succeeds once the basket closes',
    @Expected = N'1', @Actual = @s;
GO

-- =============================================
-- Test 3: the two pre-existing rejections still fire
-- =============================================
DECLARE @CavA BIGINT = (SELECT CavA FROM #ctx);

-- already deprecated by Test 2
CREATE TABLE #d (Status BIT, Message NVARCHAR(500));
INSERT INTO #d EXEC Tools.ToolCavity_Deprecate @Id = @CavA, @AppUserId = 1;
DECLARE @s NVARCHAR(1)   = (SELECT CAST(Status AS NVARCHAR(1)) FROM #d);
DECLARE @m NVARCHAR(500) = (SELECT Message FROM #d);
DROP TABLE #d;

EXEC test.Assert_IsEqual
    @TestName = N'[Cavity deprecate guard] already-deprecated still rejects',
    @Expected = N'0', @Actual = @s;
EXEC test.Assert_Contains
    @TestName = N'[Cavity deprecate guard] not-found message unchanged',
    @HaystackStr = @m, @NeedleStr = N'not found or already deprecated';

CREATE TABLE #d2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #d2 EXEC Tools.ToolCavity_Deprecate @Id = NULL, @AppUserId = 1;
DECLARE @s2 NVARCHAR(1)   = (SELECT CAST(Status AS NVARCHAR(1)) FROM #d2);
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM #d2);
DROP TABLE #d2;

EXEC test.Assert_IsEqual
    @TestName = N'[Cavity deprecate guard] missing parameter still rejects',
    @Expected = N'0', @Actual = @s2;
EXEC test.Assert_Contains
    @TestName = N'[Cavity deprecate guard] missing-parameter message unchanged',
    @HaystackStr = @m2, @NeedleStr = N'Required parameter missing';
GO

-- ---- teardown ----
DELETE FROM Lots.LotGenealogyClosure
WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CDG-%')
   OR AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CDG-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'CDG-%';
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CDG-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CDG-%';
DROP TABLE #ctx;
GO

EXEC test.PrintSummary;
GO
