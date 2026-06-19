-- =============================================
-- File:         0027_PlantFloor_Machining/060_MachiningOut_blocked_lot.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  B2 not-blocked guard for MachiningOut_AutoComplete. A Held machined
--               LOT at a Machining Cell rejects:
--                 - Status=0; rejection message cites Hold
--                 - NO MachiningOut ProductionEvent written
--               Also exercises the not-at-Cell rejection (LOT elsewhere rejects).
--               Fixture: P5-MACH-TEST eligible at MA1-COMPBR-MIN.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/060_MachiningOut_blocked_lot.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Cell, 0, @Now);
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

-- =============================================
-- Test 1: Held LOT rejects
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');

DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 24, @AppUserId = 1, @LotName = N'P5T-MO-HOLD';
SELECT @Lot = NewId FROM #C; DROP TABLE #C;
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @Lot;

DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, AutoMoved BIT, ToLocationId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningOut_AutoComplete @LotId = @Lot, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R; DROP TABLE #R;
DECLARE @Scond BIT = CASE WHEN @S = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachOutBlk] held LOT rejected', @Condition = @Scond;
EXEC test.Assert_Contains @TestName = N'[MachOutBlk] rejection cites Hold', @HaystackStr = @M, @NeedleStr = N'Hold';

DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId WHERE pe.LotId = @Lot AND ot.Code = N'MachiningOut');
EXEC test.Assert_IsEqual @TestName = N'[MachOutBlk] no MachiningOut ProductionEvent written', @Expected = N'0', @Actual = @PeCnt;
GO

-- =============================================
-- Test 2: not-at-Cell rejects
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @OtherCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-MIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- a LOT that lives at @Cell (eligible there), but we call AutoComplete claiming @OtherCell
DECLARE @Lot2 BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 24, @AppUserId = 1, @LotName = N'P5T-MO-WRONGCELL';
SELECT @Lot2 = NewId FROM #C2; DROP TABLE #C2;

DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, AutoMoved BIT, ToLocationId BIGINT);
INSERT INTO #R2 EXEC Workorder.MachiningOut_AutoComplete @LotId = @Lot2, @CellLocationId = @OtherCell, @AppUserId = 1;
SELECT @S2 = Status, @M2 = Message FROM #R2; DROP TABLE #R2;
DECLARE @S2cond BIT = CASE WHEN @S2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachOutBlk] LOT not at the specified Cell rejected', @Condition = @S2cond;
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
