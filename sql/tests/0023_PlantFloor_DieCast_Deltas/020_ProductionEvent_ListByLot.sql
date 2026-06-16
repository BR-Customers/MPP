-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/020_ProductionEvent_ListByLot.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Workorder.ProductionEvent_ListByLot (Phase 3 delta,
--               Change 2 / PE-1a). Header-only, chronological, empty-safe.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/020_ProductionEvent_ListByLot.sql';
GO

-- ---- teardown prior fixtures (FK-safe) ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN
    (SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

-- fixture: eligible Cell with NO active tool (Received origin needs no Tool/Cavity);
--          DieCastShot template for the checkpoints.
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @DcsTemplate BIGINT = (SELECT TOP 1 Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot' AND DeprecatedAt IS NULL);

DECLARE @LotId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=100, @AppUserId=1;
SELECT @LotId = NewId FROM #C; DROP TABLE #C;

-- two checkpoints, increasing cumulative shots
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId=@LotId, @OperationTemplateId=@DcsTemplate, @ShotCount=50, @ScrapCount=1, @AppUserId=1;
DELETE FROM #P;
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId=@LotId, @OperationTemplateId=@DcsTemplate, @ShotCount=120, @ScrapCount=3, @AppUserId=1;
DROP TABLE #P;
GO

-- Test 1: count + ordering + resolved columns
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id DESC);
DECLARE @R TABLE (Id BIGINT, LotId BIGINT, OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50),
    OperationTemplateName NVARCHAR(100), WorkOrderOperationId BIGINT, EventAt DATETIME2(3),
    ShotCount INT, ScrapCount INT, ScrapSourceId BIGINT, WeightValue DECIMAL(12,4), WeightUomId BIGINT,
    WeightUomCode NVARCHAR(50), AppUserId BIGINT, ByUser NVARCHAR(200), TerminalLocationId BIGINT, Remarks NVARCHAR(500));
INSERT INTO @R EXEC Workorder.ProductionEvent_ListByLot @LotId = @LotId;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM @R); DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] 2 checkpoints returned', @Expected = N'2', @Actual = @CntStr;
DECLARE @FirstShots NVARCHAR(10) = (SELECT CAST(ShotCount AS NVARCHAR(10)) FROM
    (SELECT ShotCount, ROW_NUMBER() OVER (ORDER BY EventAt ASC, Id ASC) rn FROM @R) x WHERE rn = 1);
EXEC test.Assert_IsEqual @TestName = N'[PEL] first row is earliest (50 shots)', @Expected = N'50', @Actual = @FirstShots;
DECLARE @NullCode INT = (SELECT COUNT(*) FROM @R WHERE OperationTemplateCode IS NULL);
DECLARE @NullCodeStr NVARCHAR(10) = CAST(@NullCode AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] OperationTemplateCode resolved', @Expected = N'0', @Actual = @NullCodeStr;
GO

-- Test 2: empty LOT -> 0 rows, no error
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @EmptyLot BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1;
SELECT @EmptyLot = NewId FROM #C2; DROP TABLE #C2;
DECLARE @E TABLE (Id BIGINT, LotId BIGINT, OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50),
    OperationTemplateName NVARCHAR(100), WorkOrderOperationId BIGINT, EventAt DATETIME2(3),
    ShotCount INT, ScrapCount INT, ScrapSourceId BIGINT, WeightValue DECIMAL(12,4), WeightUomId BIGINT,
    WeightUomCode NVARCHAR(50), AppUserId BIGINT, ByUser NVARCHAR(200), TerminalLocationId BIGINT, Remarks NVARCHAR(500));
INSERT INTO @E EXEC Workorder.ProductionEvent_ListByLot @LotId = @EmptyLot;
DECLARE @ECnt INT = (SELECT COUNT(*) FROM @E); DECLARE @ECntStr NVARCHAR(10) = CAST(@ECnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] empty LOT returns 0 rows', @Expected = N'0', @Actual = @ECntStr;
GO

-- Test 3: scoping — checkpoints on LOT A not returned for LOT B
DECLARE @A BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id ASC);  -- the 2-checkpoint LOT
DECLARE @B BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id DESC); -- the empty LOT
-- (Id ASC = first-created = the 2-checkpoint LOT; Id DESC = last-created = the empty LOT.)
DECLARE @B2 TABLE (Id BIGINT, LotId BIGINT, OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50),
    OperationTemplateName NVARCHAR(100), WorkOrderOperationId BIGINT, EventAt DATETIME2(3),
    ShotCount INT, ScrapCount INT, ScrapSourceId BIGINT, WeightValue DECIMAL(12,4), WeightUomId BIGINT,
    WeightUomCode NVARCHAR(50), AppUserId BIGINT, ByUser NVARCHAR(200), TerminalLocationId BIGINT, Remarks NVARCHAR(500));
INSERT INTO @B2 EXEC Workorder.ProductionEvent_ListByLot @LotId = @B;
DECLARE @Leak INT = (SELECT COUNT(*) FROM @B2 WHERE LotId = @A);
DECLARE @LeakStr NVARCHAR(10) = CAST(@Leak AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] no cross-LOT leakage', @Expected = N'0', @Actual = @LeakStr;
GO

-- ---- teardown ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN
    (SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO
EXEC test.EndTestFile;
GO
