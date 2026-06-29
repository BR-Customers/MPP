-- =============================================
-- File:         0027_PlantFloor_Machining/040_MachiningOut_AutoComplete_coupled.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Coupled PLC auto-complete (FDS-06-008) for MachiningOut_AutoComplete.
--               A machined LOT at a Machining Cell whose CoupledDownstreamCellLocationId
--               is set => closing ProductionEvent + auto-move to the coupled Cell:
--                 - Status=1; ProductionEventId returned; AutoMoved=1;
--                   ToLocationId = coupled Cell
--                 - MachiningOut ProductionEvent written
--                 - LotMovement Cell->coupled written; Lot.CurrentLocationId = coupled
--                 - MachiningOutAutoMoved audit in OperationLog
--               Fixture: P5-MACH-TEST machined Item Direct-eligible at the Cell
--               MA1-COMPBR-MIN; CoupledDownstreamCellLocationId temporarily set to
--               MA1-COMPBR-AOUT for this test (restored in cleanup).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/040_MachiningOut_AutoComplete_coupled.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Coupled BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Cell, 0, @Now);

-- set the coupling for the test
UPDATE Location.Location SET CoupledDownstreamCellLocationId = @Coupled WHERE Id = @Cell;
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
DECLARE @Coupled BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- a machined LOT at the Cell
DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 24, @AppUserId = 1, @LotName = N'P5T-MO-COUP';
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT, @ProdId BIGINT, @AutoMoved BIT, @ToLoc BIGINT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, AutoMoved BIT, ToLocationId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningOut_AutoComplete @LotId = @Lot, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S = Status, @ProdId = ProductionEventId, @AutoMoved = AutoMoved, @ToLoc = ToLocationId FROM #R; DROP TABLE #R;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @ProdStr NVARCHAR(20) = CAST(@ProdId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[MachOutCoup] ProductionEventId returned', @Value = @ProdStr;

DECLARE @AmStr NVARCHAR(10) = CAST(@AutoMoved AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] AutoMoved=1', @Expected = N'1', @Actual = @AmStr;

DECLARE @ToStr NVARCHAR(20) = CAST(@ToLoc AS NVARCHAR(20));
DECLARE @CoupStr NVARCHAR(20) = CAST(@Coupled AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] ToLocationId = coupled Cell', @Expected = @CoupStr, @Actual = @ToStr;

-- MachiningOut ProductionEvent written
DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId WHERE pe.Id = @ProdId AND pe.LotId = @Lot AND ot.Code = N'MachiningOut');
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] MachiningOut ProductionEvent written', @Expected = N'1', @Actual = @PeCnt;

-- LotMovement to coupled + CurrentLocationId updated
DECLARE @MovCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement WHERE LotId = @Lot AND FromLocationId = @Cell AND ToLocationId = @Coupled);
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] LotMovement Cell->coupled written', @Expected = N'1', @Actual = @MovCnt;

DECLARE @Cur NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] Lot.CurrentLocationId = coupled Cell', @Expected = @CoupStr, @Actual = @Cur;

-- audit
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'MachiningOutAutoMoved' AND ol.EntityId = @ProdId);
EXEC test.Assert_IsEqual @TestName = N'[MachOutCoup] MachiningOutAutoMoved audit in OperationLog', @Expected = N'1', @Actual = @AudCnt;
GO

-- ---- cleanup (LOT + restore coupling) ----
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
UPDATE Location.Location SET CoupledDownstreamCellLocationId = NULL WHERE Id = @Cell;
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-MO%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-MO%';
GO

EXEC test.EndTestFile;
GO
