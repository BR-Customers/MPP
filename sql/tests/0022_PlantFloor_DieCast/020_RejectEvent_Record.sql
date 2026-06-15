-- =============================================
-- File:         0022_PlantFloor_DieCast/020_RejectEvent_Record.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-15
-- Description:  Tests for Workorder.RejectEvent_Record (Arc 2 Phase 3 §4.2 + D3).
--               Covers:
--                 - valid partial reject -> Status=1, RejectEvent row, D3
--                   Lot.PieceCount + InventoryAvailable decremented, LOT stays Good
--                 - D3 close-at-zero: rejecting all remaining pieces -> LOT
--                   Closed + LotStatusHistory (Good->Closed) row + routed
--                   'LotStatusChanged' op in LotEventLog
--                 - reject Quantity > remaining pieces -> reject
--                 - Quantity <= 0 -> reject
--                 - held (Hold) LOT -> reject
--                 - already-Closed LOT -> reject
--                 - invalid DefectCode -> reject
--                 - missing required param -> reject
--                 - reject audit op written to OperationLog (RejectEvent entity)
--
--               EXEC args are pre-assigned @variables (no inline CAST).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/020_RejectEvent_Record.sql';
GO

-- ---- cleanup any prior fixtures ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ';
GO

-- ---- fixture: a DefectCode (Quality.DefectCode is empty in dev/test; the FRS
--      153-defect seed is a cutover-only load). Bound to the first active Area. ----
DECLARE @AreaId BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-RJ', N'Reject test defect', @AreaId, 0, SYSUTCDATETIME());
GO

-- =============================================
-- Test 1: valid partial reject -> D3 decrement, LOT stays Good
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

DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');

DECLARE @S BIT, @NewId BIGINT;
CREATE TABLE #T1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T1 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 3, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId FROM #T1;
DROP TABLE #T1;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReValid] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @RowCnt INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE Id = @NewId AND LotId = @LotId);
DECLARE @RowCntStr NVARCHAR(10) = CAST(@RowCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReValid] RejectEvent row exists', @Expected = N'1', @Actual = @RowCntStr;

DECLARE @Pc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @Inv INT = (SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PcStr NVARCHAR(10) = CAST(@Pc AS NVARCHAR(10));
DECLARE @InvStr NVARCHAR(10) = CAST(@Inv AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReValid][D3] PieceCount 10-3=7', @Expected = N'7', @Actual = @PcStr;
EXEC test.Assert_IsEqual @TestName = N'[ReValid][D3] InventoryAvailable 10-3=7', @Expected = N'7', @Actual = @InvStr;

DECLARE @StatusCode NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @LotId);
EXEC test.Assert_IsEqual @TestName = N'[ReValid] LOT still Good after partial reject', @Expected = N'Good', @Actual = @StatusCode;

DECLARE @AudCnt INT = (SELECT COUNT(*) FROM Audit.OperationLog ol
    INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
    WHERE et.Code = N'RejectEventRecorded' AND ol.EntityId = @NewId);
DECLARE @AudStr NVARCHAR(10) = CAST(@AudCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReValid] Reject audit op in OperationLog', @Expected = N'1', @Actual = @AudStr;
GO

-- =============================================
-- Test 2: D3 close-at-zero -> reject remaining 7 pieces -> LOT Closed
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @Remaining INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);  -- 7

DECLARE @S BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = @Remaining, @AppUserId = 1;
SELECT @S = Status FROM #T2;
DROP TABLE #T2;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReZero] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @Pc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PcStr NVARCHAR(10) = CAST(@Pc AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReZero] PieceCount is 0', @Expected = N'0', @Actual = @PcStr;

DECLARE @StatusCode NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @LotId);
EXEC test.Assert_IsEqual @TestName = N'[ReZero] LOT auto-Closed at zero', @Expected = N'Closed', @Actual = @StatusCode;

DECLARE @HistCnt INT = (SELECT COUNT(*) FROM Lots.LotStatusHistory lsh
    INNER JOIN Lots.LotStatusCode oc ON oc.Id = lsh.OldStatusId
    INNER JOIN Lots.LotStatusCode nc ON nc.Id = lsh.NewStatusId
    WHERE lsh.LotId = @LotId AND oc.Code = N'Good' AND nc.Code = N'Closed');
DECLARE @HistStr NVARCHAR(10) = CAST(@HistCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReZero] Good->Closed LotStatusHistory row', @Expected = N'1', @Actual = @HistStr;

DECLARE @LelCnt INT = (SELECT COUNT(*) FROM Lots.LotEventLog lel
    INNER JOIN Audit.LogEventType et ON et.Id = lel.LogEventTypeId
    WHERE et.Code = N'LotStatusChanged' AND lel.LotId = @LotId);
DECLARE @LelStr NVARCHAR(10) = CAST(@LelCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReZero] Close op routed to LotEventLog', @Expected = N'1', @Actual = @LelStr;
GO

-- =============================================
-- Test 3: reject on an already-Closed LOT -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @S BIT;
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T3 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 1, @AppUserId = 1;
SELECT @S = Status FROM #T3;
DROP TABLE #T3;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReClosed] Reject on Closed LOT rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: Quantity > remaining -> reject (fresh LOT)
-- =============================================
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @LotId BIGINT;
CREATE TABLE #C4 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C4 EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 5, @AppUserId = 1;
SELECT @LotId = NewId FROM #C4;
DROP TABLE #C4;

DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @S BIT;
CREATE TABLE #T4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T4 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 99, @AppUserId = 1;
SELECT @S = Status FROM #T4;
DROP TABLE #T4;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReOver] Reject Quantity over remaining', @Expected = N'0', @Actual = @SStr;

DECLARE @Pc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PcStr NVARCHAR(10) = CAST(@Pc AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReOver] PieceCount unchanged after rejected reject', @Expected = N'5', @Actual = @PcStr;
GO

-- =============================================
-- Test 5: Quantity <= 0 -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' AND PieceCount > 0 ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @S BIT;
CREATE TABLE #T5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 0, @AppUserId = 1;
SELECT @S = Status FROM #T5;
DROP TABLE #T5;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReZeroQty] Reject zero Quantity', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 6: held (Hold) LOT -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' AND PieceCount > 0 ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @LotId;
DECLARE @S BIT;
CREATE TABLE #T6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T6 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 1, @AppUserId = 1;
SELECT @S = Status FROM #T6;
DROP TABLE #T6;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReHeld] Reject on Hold LOT rejected', @Expected = N'0', @Actual = @SStr;
DECLARE @GoodId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
UPDATE Lots.Lot SET LotStatusId = @GoodId WHERE Id = @LotId;
GO

-- =============================================
-- Test 7: invalid DefectCode -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' AND PieceCount > 0 ORDER BY Id);
DECLARE @S BIT;
CREATE TABLE #T7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T7 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = 999999999, @Quantity = 1, @AppUserId = 1;
SELECT @S = Status FROM #T7;
DROP TABLE #T7;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReBadDefect] Reject invalid DefectCode', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 8: missing @AppUserId -> reject
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' AND PieceCount > 0 ORDER BY Id);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @S BIT;
CREATE TABLE #T8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T8 EXEC Workorder.RejectEvent_Record
    @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 1, @AppUserId = NULL;
SELECT @S = Status FROM #T8;
DROP TABLE #T8;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[ReNoUser] Reject missing @AppUserId', @Expected = N'0', @Actual = @SStr;
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ';
GO

EXEC test.EndTestFile;
GO
