-- =============================================
-- File:         0022_PlantFloor_DieCast/010_ProductionEvent_Record.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-15
-- Description:  Tests for Workorder.ProductionEvent_Record (Arc 2 Phase 3 §4.1).
--               Covers:
--                 - valid checkpoint -> ProductionEvent row, Status=1
--                 - D2: Lot.PieceCount / InventoryAvailable UNCHANGED by a
--                   checkpoint
--                 - D1: cumulative ShotCount/ScrapCount stored verbatim; a
--                   second checkpoint with a higher cumulative is accepted
--                 - D1: a checkpoint with a LOWER cumulative ShotCount -> reject
--                 - optional ProductionEventValue children persisted from JSON
--                 - held (Hold-status) LOT -> reject (inlined not-blocked guard)
--                 - non-existent LOT -> reject
--                 - missing required param (@OperationTemplateId) -> reject
--                 - missing @AppUserId -> reject
--                 - invalid OperationTemplate -> reject
--                 - audit op written to Audit.OperationLog
--
--               NOTE: EXEC parameters are pre-assigned @variables (never inline
--               CAST/arithmetic) per the SP-template convention.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/010_ProductionEvent_Record.sql';
GO

-- ---- shared fixture cleanup ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe
    INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

-- =============================================
-- Test 1: valid checkpoint -> Status=1, row written, D2 Lot unchanged
-- =============================================
DECLARE @CellId BIGINT, @ItemId BIGINT, @OriginRcv BIGINT;
SET @OriginRcv = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @LotId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 20, @AppUserId = 1;
SELECT @LotId = NewId FROM #C;
DROP TABLE #C;

DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @PriorPc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PriorInv INT = (SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @LotId);

DECLARE @S BIT, @NewId BIGINT;
CREATE TABLE #T1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T1 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId,
    @ShotCount = 5, @ScrapCount = 1, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId FROM #T1;
DROP TABLE #T1;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeValid] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[PeValid] NewId returned', @Value = @NewIdStr;

DECLARE @RowCnt INT = (SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE Id = @NewId AND LotId = @LotId);
DECLARE @RowCntStr NVARCHAR(10) = CAST(@RowCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeValid] ProductionEvent row exists', @Expected = N'1', @Actual = @RowCntStr;

DECLARE @Shot INT = (SELECT ShotCount FROM Workorder.ProductionEvent WHERE Id = @NewId);
DECLARE @ShotStr NVARCHAR(10) = CAST(@Shot AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeValid] ShotCount stored verbatim', @Expected = N'5', @Actual = @ShotStr;

-- D2: Lot quantities unchanged by a checkpoint
DECLARE @NowPc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @NowInv INT = (SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PriorPcStr NVARCHAR(10) = CAST(@PriorPc AS NVARCHAR(10));
DECLARE @NowPcStr NVARCHAR(10) = CAST(@NowPc AS NVARCHAR(10));
DECLARE @PriorInvStr NVARCHAR(10) = CAST(@PriorInv AS NVARCHAR(10));
DECLARE @NowInvStr NVARCHAR(10) = CAST(@NowInv AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeValid][D2] Lot.PieceCount unchanged', @Expected = @PriorPcStr, @Actual = @NowPcStr;
EXEC test.Assert_IsEqual @TestName = N'[PeValid][D2] Lot.InventoryAvailable unchanged', @Expected = @PriorInvStr, @Actual = @NowInvStr;

-- Audit op written to OperationLog (Workorder entity routes there, not LotEventLog)
DECLARE @AudCnt INT = (SELECT COUNT(*) FROM Audit.OperationLog ol
    INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
    WHERE et.Code = N'DieCastCheckpointRecorded' AND ol.EntityId = @NewId);
DECLARE @AudCntStr NVARCHAR(10) = CAST(@AudCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeValid] Audit op in OperationLog', @Expected = N'1', @Actual = @AudCntStr;
GO

-- =============================================
-- Test 2: D1 higher cumulative accept; lower cumulative ShotCount reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');

DECLARE @S BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId,
    @ShotCount = 9, @ScrapCount = 2, @AppUserId = 1;   -- 9 >= prior 5 OK
SELECT @S = Status FROM #T2;
DROP TABLE #T2;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeMonoUp] Higher cumulative accepted', @Expected = N'1', @Actual = @SStr;

DECLARE @S2 BIT;
CREATE TABLE #T2b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2b EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId,
    @ShotCount = 3, @ScrapCount = 2, @AppUserId = 1;   -- 3 < prior 9 -> reject
SELECT @S2 = Status FROM #T2b;
DROP TABLE #T2b;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeMonoDown] Lower cumulative ShotCount rejected', @Expected = N'0', @Actual = @S2Str;
GO

-- =============================================
-- Test 3: optional ProductionEventValue children from JSON
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @Dcf BIGINT = (SELECT TOP 1 Id FROM Parts.DataCollectionField WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Json NVARCHAR(MAX) = N'[{"DataCollectionFieldId":' + CAST(@Dcf AS NVARCHAR(20)) + N',"Value":"OK","NumericValue":12.5}]';

DECLARE @S BIT, @NewId BIGINT;
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T3 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId,
    @ShotCount = 12, @ScrapCount = 2, @FieldValuesJson = @Json, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId FROM #T3;
DROP TABLE #T3;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeFields] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @ChildCnt INT = (SELECT COUNT(*) FROM Workorder.ProductionEventValue WHERE ProductionEventId = @NewId);
DECLARE @ChildStr NVARCHAR(10) = CAST(@ChildCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeFields] One ProductionEventValue child', @Expected = N'1', @Actual = @ChildStr;
GO

-- =============================================
-- Test 4: held (Hold) LOT -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @LotId;

DECLARE @S BIT;
CREATE TABLE #T4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T4 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId, @ShotCount = 20, @AppUserId = 1;
SELECT @S = Status FROM #T4;
DROP TABLE #T4;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeHeld] Reject checkpoint on Hold LOT', @Expected = N'0', @Actual = @SStr;

DECLARE @GoodId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
UPDATE Lots.Lot SET LotStatusId = @GoodId WHERE Id = @LotId;
GO

-- =============================================
-- Test 5: non-existent LOT -> reject
-- =============================================
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @S BIT;
CREATE TABLE #T5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5 EXEC Workorder.ProductionEvent_Record
    @LotId = 999999999, @OperationTemplateId = @OtId, @ShotCount = 1, @AppUserId = 1;
SELECT @S = Status FROM #T5;
DROP TABLE #T5;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeNoLot] Reject non-existent LOT', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 6: missing @OperationTemplateId -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @S BIT;
CREATE TABLE #T6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T6 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = NULL, @ShotCount = 1, @AppUserId = 1;
SELECT @S = Status FROM #T6;
DROP TABLE #T6;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeNoTemplate] Reject missing OperationTemplateId', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 7: missing @AppUserId -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @S BIT;
CREATE TABLE #T7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T7 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId, @ShotCount = 1, @AppUserId = NULL;
SELECT @S = Status FROM #T7;
DROP TABLE #T7;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeNoUser] Reject missing @AppUserId', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 8: invalid OperationTemplate id -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @S BIT;
CREATE TABLE #T8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T8 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = 999999999, @ShotCount = 1, @AppUserId = 1;
SELECT @S = Status FROM #T8;
DROP TABLE #T8;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeBadTemplate] Reject invalid OperationTemplate', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 9: negative ShotCount -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @S BIT;
CREATE TABLE #T9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T9 EXEC Workorder.ProductionEvent_Record
    @LotId = @LotId, @OperationTemplateId = @OtId, @ShotCount = -1, @AppUserId = 1;
SELECT @S = Status FROM #T9;
DROP TABLE #T9;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PeNegShot] Reject negative ShotCount', @Expected = N'0', @Actual = @SStr;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe
    INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
