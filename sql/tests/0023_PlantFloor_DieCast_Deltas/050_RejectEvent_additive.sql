-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/050_RejectEvent_additive.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-21
-- Description:  Additive-vs-subtractive scrap (migration 0042 + RejectEvent_Record).
--               Die-cast scrap (@OperationTypeCode with OperationType.ScrapIsAdditive=1)
--               is recorded but does NOT decrement the LOT (bad shots never entered the
--               basket -> the LOT holds the fulfilled good count). Downstream / unknown
--               (default) stays subtractive (D3). The LOT's origin is irrelevant here --
--               the rule keys on the reject's operation context, not the LOT.
--
--               EXEC args are pre-assigned @variables (no inline CAST).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/050_RejectEvent_additive.sql';
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-ADD';
GO

-- ---- fixture: a DefectCode bound to the first active Area ----
DECLARE @AreaId BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-ADD', N'Additive reject test defect', @AreaId, 0, SYSUTCDATETIME());
GO

-- =============================================
-- Test 0: the reference rule is seeded (DieCast additive, others subtractive)
-- =============================================
DECLARE @DcAdd NVARCHAR(10) = CAST((SELECT ScrapIsAdditive FROM Parts.OperationType WHERE Code = N'DieCast') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ScrapRule] DieCast ScrapIsAdditive = 1', @Expected = N'1', @Actual = @DcAdd;
DECLARE @ToAdd NVARCHAR(10) = CAST((SELECT ScrapIsAdditive FROM Parts.OperationType WHERE Code = N'TrimOut') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ScrapRule] TrimOut ScrapIsAdditive = 0', @Expected = N'0', @Actual = @ToAdd;
GO

-- =============================================
-- Test 1: additive (DieCast) reject -> recorded, LOT PieceCount UNCHANGED, stays Good
-- =============================================
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @LotId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 10, @AppUserId = 1;
SELECT @LotId = NewId FROM #C;
DROP TABLE #C;

DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-ADD');
DECLARE @S BIT, @NewId BIGINT;
CREATE TABLE #T1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T1 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 4, @AppUserId = 1, @OperationTypeCode = N'DieCast';
SELECT @S = Status, @NewId = NewId FROM #T1;
DROP TABLE #T1;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Additive] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @RowCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE Id = @NewId AND LotId = @LotId AND Quantity = 4) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Additive] RejectEvent recorded (qty 4)', @Expected = N'1', @Actual = @RowCnt;

DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Additive] PieceCount UNCHANGED at 10', @Expected = N'10', @Actual = @Pc;

DECLARE @Inv NVARCHAR(10) = CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @LotId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Additive] InventoryAvailable UNCHANGED at 10', @Expected = N'10', @Actual = @Inv;

DECLARE @Sc NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @LotId);
EXEC test.Assert_IsEqual @TestName = N'[Additive] LOT stays Good', @Expected = N'Good', @Actual = @Sc;
GO

-- =============================================
-- Test 2: additive reject Quantity > PieceCount -> accepted (no over-reject cap), still unchanged
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-ADD');
DECLARE @S BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 999, @AppUserId = 1, @OperationTypeCode = N'DieCast';
SELECT @S = Status FROM #T2;
DROP TABLE #T2;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AdditiveOver] Qty over PieceCount accepted (no cap)', @Expected = N'1', @Actual = @SStr;
DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AdditiveOver] PieceCount still 10', @Expected = N'10', @Actual = @Pc;
GO

-- =============================================
-- Test 3: subtractive default (no @OperationTypeCode) -> still decrements (backward compat)
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-ADD');
DECLARE @S BIT;
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T3 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 4, @AppUserId = 1;
SELECT @S = Status FROM #T3;
DROP TABLE #T3;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Subtractive] Status is 1', @Expected = N'1', @Actual = @SStr;
DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Subtractive] PieceCount decremented 10-4=6', @Expected = N'6', @Actual = @Pc;
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-ADD';
GO

EXEC test.EndTestFile;
GO
