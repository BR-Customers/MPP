-- =============================================
-- File:         0027_PlantFloor_Machining/050_MachiningOut_AutoComplete_uncoupled.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Uncoupled PLC auto-complete (FDS-06-008 legacy path) for
--               MachiningOut_AutoComplete. A machined LOT at a Machining Cell whose
--               CoupledDownstreamCellLocationId is NULL => closing ProductionEvent
--               ONLY, no auto-move:
--                 - Status=1; ProductionEventId returned; AutoMoved=0;
--                   ToLocationId NULL
--                 - MachiningOut ProductionEvent written
--                 - NO LotMovement off the Cell; Lot.CurrentLocationId unchanged
--                 - MachiningOutCompleted audit in OperationLog
--               Fixture: P5-MACH-TEST eligible at MA1-COMPBR-MIN; coupling left NULL.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/050_MachiningOut_AutoComplete_uncoupled.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Cell, 0, @Now);

-- ensure NOT coupled
UPDATE Location.Location SET CoupledDownstreamCellLocationId = NULL WHERE Id = @Cell;
GO

-- ---- LOT cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-MO%';
GO

-- ====================================================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 24, @AppUserId = 1, @LotName = N'P5T-MO-UNC';
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT, @ProdId BIGINT, @AutoMoved BIT, @ToLoc BIGINT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, AutoMoved BIT, ToLocationId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningOut_AutoComplete @LotId = @Lot, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S = Status, @ProdId = ProductionEventId, @AutoMoved = AutoMoved, @ToLoc = ToLocationId FROM #R; DROP TABLE #R;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachOutUnc] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @AmStr NVARCHAR(10) = CAST(@AutoMoved AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachOutUnc] AutoMoved=0', @Expected = N'0', @Actual = @AmStr;

DECLARE @ToStr NVARCHAR(20) = CAST(@ToLoc AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[MachOutUnc] ToLocationId NULL', @Value = @ToStr;

-- ProductionEvent written
DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId WHERE pe.Id = @ProdId AND pe.LotId = @Lot AND ot.Code = N'MachiningOut');
EXEC test.Assert_IsEqual @TestName = N'[MachOutUnc] MachiningOut ProductionEvent written', @Expected = N'1', @Actual = @PeCnt;

-- no movement off the Cell (only the first-placement From=NULL->Cell row from create)
DECLARE @OffCell NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement WHERE LotId = @Lot AND FromLocationId = @Cell);
EXEC test.Assert_IsEqual @TestName = N'[MachOutUnc] no LotMovement off the Cell', @Expected = N'0', @Actual = @OffCell;

DECLARE @Cur NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @CellStr NVARCHAR(20) = CAST(@Cell AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachOutUnc] Lot.CurrentLocationId unchanged (stays at Cell)', @Expected = @CellStr, @Actual = @Cur;

-- audit
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'MachiningOutCompleted' AND ol.EntityId = @ProdId);
EXEC test.Assert_IsEqual @TestName = N'[MachOutUnc] MachiningOutCompleted audit in OperationLog', @Expected = N'1', @Actual = @AudCnt;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-MO%';
GO

EXEC test.EndTestFile;
GO
