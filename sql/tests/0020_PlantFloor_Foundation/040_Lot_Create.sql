-- =============================================
-- File:         0020_PlantFloor_Foundation/040_Lot_Create.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Lots.Lot_Create. Covers the validation rejections
--               and the accept paths from the plan section "API Layer" / B-3:
--                 - valid manufacture -> Lot + LotStatusHistory, Tool/Cavity
--                   set, MintedLotName ~ 'MESL%'
--                 - die-cast-origin (active ToolAssignment on cell) + NULL
--                   @ToolId -> reject
--                 - @ToolId not mounted on @CurrentLocationId -> reject
--                 - @ToolCavityId not belonging to @ToolId -> reject
--                 - cavity status <> Active -> reject
--                 - non-die-cast origin with NULL Tool/Cavity -> accept
--                 - Item ineligible at location -> reject
--                 - piece count > Item.MaxLotSize -> reject
--                 - missing @AppUserId -> reject
--
--               Fixtures: eligible (Item,Cell) pairs come from seeds
--               (v_EffectiveItemLocation). A Tool + ToolCavity (+ a Closed
--               cavity) + ToolAssignment are created here on a die-cast Cell.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/040_Lot_Create.sql';
GO

-- ---- shared fixture ----
-- Pick a Direct-eligible (Item, Cell) pair for the die-cast cell, and a
-- DIFFERENT Direct-eligible (Item, Cell) pair (no tool) for the non-die-cast
-- accept path. Create a Tool with an Active cavity + a Closed cavity, and mount
-- the Tool on the die-cast cell.
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' AND CreatedByUserId = 1
    AND ItemId IN (SELECT Id FROM Parts.Item);  -- conservative no-op guard (real cleanup below)
GO

-- Clean any prior fixture artifacts (reverse FK order)
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-LC-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-LC-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-LC-TOOL';
GO

DECLARE @DieCellId BIGINT, @DieItemId BIGINT;
SELECT TOP 1 @DieItemId = ItemId, @DieCellId = LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Location.Location l ON l.Id = eil.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.Code = N'Cell' AND eil.Source = N'Direct'
ORDER BY eil.LocationId;

-- Create the test Tool
DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-LC-TOOL', N'Lot_Create test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

-- Two cavities: one Active, one Closed
DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @CavClosed BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, N'1', @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, N'2', @CavClosed, SYSUTCDATETIME(), 1);

-- Mount on the die-cast cell
INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @DieCellId, SYSUTCDATETIME(), 1);
GO

-- =============================================
-- Test 1: valid die-cast manufacture -> Lot + history, Tool/Cavity set, MESL name
-- =============================================
DECLARE @DieCellId BIGINT, @DieItemId BIGINT, @ToolId BIGINT, @CavId BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT @ToolId = Id FROM Tools.Tool WHERE Code = N'TEST-LC-TOOL';
SELECT @DieCellId = CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL;
SELECT @CavId = Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = N'1';
SELECT TOP 1 @DieItemId = ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct';

DECLARE @S BIT, @SStr NVARCHAR(1), @NewId BIGINT, @Minted NVARCHAR(50);
CREATE TABLE #T1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T1 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @ToolId, @ToolCavityId = @CavId, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId, @Minted = MintedLotName FROM #T1;
DROP TABLE #T1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcValid] Status is 1', @Expected = N'1', @Actual = @SStr;
EXEC test.Assert_Contains @TestName = N'[LcValid] MintedLotName starts MESL', @HaystackStr = @Minted, @NeedleStr = N'MESL';

DECLARE @HistCnt INT = (SELECT COUNT(*) FROM Lots.LotStatusHistory WHERE LotId = @NewId AND OldStatusId IS NULL);
DECLARE @HistStr NVARCHAR(10) = CAST(@HistCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LcValid] One initial LotStatusHistory row', @Expected = N'1', @Actual = @HistStr;

DECLARE @ToolSet NVARCHAR(1) = (SELECT CASE WHEN ToolId IS NOT NULL AND ToolCavityId IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @NewId);
EXEC test.Assert_IsEqual @TestName = N'[LcValid] Tool/Cavity set on the Lot', @Expected = N'1', @Actual = @ToolSet;

DECLARE @InvAvail INT = (SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @NewId);
DECLARE @InvStr NVARCHAR(10) = CAST(@InvAvail AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LcValid] InventoryAvailable seeded to PieceCount', @Expected = N'10', @Actual = @InvStr;
GO

-- =============================================
-- Test 2: die-cast cell + NULL @ToolId -> reject
-- =============================================
DECLARE @DieCellId BIGINT, @DieItemId BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT @DieCellId = CellLocationId FROM Tools.ToolAssignment ta INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'TEST-LC-TOOL' AND ta.ReleasedAt IS NULL;
SELECT TOP 1 @DieItemId = ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct';

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T2 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = NULL, @ToolCavityId = NULL, @AppUserId = 1;
SELECT @S = Status FROM #T2;
DROP TABLE #T2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcDieNoTool] Reject die-cast with NULL Tool', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: @ToolId not mounted on the cell -> reject
--   Use a real Tool id that is NOT assigned to the die cell. Create a second
--   unmounted tool to guarantee a valid-but-unmounted Tool id.
-- =============================================
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-LC-TOOL2';
DELETE FROM Tools.Tool WHERE Code = N'TEST-LC-TOOL2';
DECLARE @TT BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @TA BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@TT, N'TEST-LC-TOOL2', N'Unmounted die', @TA, SYSUTCDATETIME(), 1);
DECLARE @Tool2 BIGINT = SCOPE_IDENTITY();
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool2, N'1', @CavA, SYSUTCDATETIME(), 1);
DECLARE @Cav2 BIGINT = SCOPE_IDENTITY();

DECLARE @DieCellId BIGINT, @DieItemId BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT @DieCellId = CellLocationId FROM Tools.ToolAssignment ta INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'TEST-LC-TOOL' AND ta.ReleasedAt IS NULL;
SELECT TOP 1 @DieItemId = ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct';

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T3 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @Tool2, @ToolCavityId = @Cav2, @AppUserId = 1;
SELECT @S = Status FROM #T3;
DROP TABLE #T3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcToolNotMounted] Reject unmounted Tool', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: cavity not belonging to the mounted tool -> reject
--   Mounted tool = TEST-LC-TOOL; cavity from TEST-LC-TOOL2.
-- =============================================
DECLARE @DieCellId BIGINT, @DieItemId BIGINT, @ToolId BIGINT, @ForeignCav BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT @ToolId = Id FROM Tools.Tool WHERE Code = N'TEST-LC-TOOL';
SELECT @DieCellId = CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL;
SELECT TOP 1 @DieItemId = ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct';
SELECT @ForeignCav = tc.Id FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-LC-TOOL2';

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T4 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T4 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @ToolId, @ToolCavityId = @ForeignCav, @AppUserId = 1;
SELECT @S = Status FROM #T4;
DROP TABLE #T4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcCavWrongTool] Reject cavity of a different tool', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 5: cavity status <> Active (Closed cavity) -> reject
-- =============================================
DECLARE @DieCellId BIGINT, @DieItemId BIGINT, @ToolId BIGINT, @ClosedCav BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT @ToolId = Id FROM Tools.Tool WHERE Code = N'TEST-LC-TOOL';
SELECT @DieCellId = CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL;
SELECT TOP 1 @DieItemId = ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct';
SELECT @ClosedCav = Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = N'2';  -- the Closed cavity

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T5 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @ToolId, @ToolCavityId = @ClosedCav, @AppUserId = 1;
SELECT @S = Status FROM #T5;
DROP TABLE #T5;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcCavClosed] Reject non-Active cavity', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 6: non-die-cast origin (Received), NULL Tool/Cavity, on a cell with no
--   tool -> accept. Use an eligible (Item, Cell) pair with no ToolAssignment.
-- =============================================
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @S BIT, @SStr NVARCHAR(1), @NewId BIGINT;
CREATE TABLE #T6 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T6 EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 5, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId FROM #T6;
DROP TABLE #T6;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcNonDieCast] Accept non-die-cast with NULL Tool/Cavity', @Expected = N'1', @Actual = @SStr;

DECLARE @NullTool NVARCHAR(1) = (SELECT CASE WHEN ToolId IS NULL AND ToolCavityId IS NULL THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @NewId);
EXEC test.Assert_IsEqual @TestName = N'[LcNonDieCast] Tool/Cavity NULL on the Lot', @Expected = N'1', @Actual = @NullTool;
GO

-- =============================================
-- Test 7: Item ineligible at location -> reject
--   Pick an (Item, Location) pair NOT present in v_EffectiveItemLocation.
-- =============================================
DECLARE @ItemId BIGINT, @BadLocId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id;
SELECT TOP 1 @BadLocId = l.Id FROM Location.Location l
WHERE l.DeprecatedAt IS NULL
  AND NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e WHERE e.ItemId = @ItemId AND e.LocationId = l.Id)
ORDER BY l.Id;

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T7 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T7 EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @BadLocId,
    @PieceCount = 5, @AppUserId = 1;
SELECT @S = Status FROM #T7;
DROP TABLE #T7;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcIneligible] Reject ineligible Item-at-Location', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 8: piece count > Item.MaxLotSize -> reject
--   Set a small MaxLotSize on an eligible item, then exceed it.
-- =============================================
DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @PriorMax INT = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
UPDATE Parts.Item SET MaxLotSize = 4 WHERE Id = @ItemId;

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T8 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T8 EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 99, @AppUserId = 1;
SELECT @S = Status FROM #T8;
DROP TABLE #T8;

-- restore MaxLotSize
UPDATE Parts.Item SET MaxLotSize = @PriorMax WHERE Id = @ItemId;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcOverMax] Reject piece count over MaxLotSize', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 9: missing @AppUserId -> reject
-- =============================================
DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;

DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #T9 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #T9 EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 5, @AppUserId = NULL;
SELECT @S = Status FROM #T9;
DROP TABLE #T9;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[LcNoUser] Reject missing @AppUserId', @Expected = N'0', @Actual = @SStr;
GO

-- ---- cleanup fixtures ----
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-LC-TOOL', N'TEST-LC-TOOL2');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code IN (N'TEST-LC-TOOL', N'TEST-LC-TOOL2'));
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-LC-TOOL', N'TEST-LC-TOOL2');
GO

EXEC test.EndTestFile;
GO
