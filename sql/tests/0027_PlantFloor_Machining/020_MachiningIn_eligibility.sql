-- =============================================
-- File:         0027_PlantFloor_Machining/020_MachiningIn_eligibility.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Eligibility (OI-18 / FDS-02-012) for MachiningIn_PickAndConsume.
--                 - BomDerived eligibility resolves: machined Item Direct-eligible
--                   at the Cell => the cast/trim source resolves BomDerived and the
--                   pick SUCCEEDS.
--                 - ineligible source (no eligibility path at the Cell) rejects
--                   (the eligibility check is reached AFTER the BOM resolves).
--               Reuses the P5-CAST-TEST / P5-MACH-TEST fixture from 010; adds a
--               second Machining-In Cell (MA1-6MD-MIN) where the machined Item is
--               NOT eligible to exercise the rejection.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/020_MachiningIn_eligibility.sql';
GO

-- ---- fixture (idempotent; mirrors 010) ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P5-CAST-TEST', N'Phase5 test cast/trim part', 48, NULL, 1, @Now, 1);
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 24, NULL, 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @MachItem AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (@MachItem, 1, '2026-01-01', '2026-01-01', NULL, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @SrcItem, 1.0, 1, 1);
END
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Cell, 0, @Now);
GO

-- ---- LOT cleanup ----
DELETE ce FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId WHERE l.LotName LIKE N'P5T%';
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE ac FROM Lots.LotAttributeChange ac INNER JOIN Lots.Lot l ON l.Id = ac.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
GO

-- =============================================
-- Test 1: BomDerived eligibility resolves -> pick succeeds
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

-- source Item is BomDerived-eligible at the Cell (machined parent Direct-eligible there)
DECLARE @ElCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.v_EffectiveItemLocation WHERE ItemId = @SrcItem AND LocationId = @Cell AND Source = N'BomDerived');
EXEC test.Assert_IsEqual @TestName = N'[MachInElig] source resolves BomDerived at the Cell', @Expected = N'1', @Actual = @ElCnt;

DECLARE @SrcLot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 30, @AppUserId = 1, @LotName = N'P5T-SRC-020';
SELECT @SrcLot = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningIn_PickAndConsume @SourceLotId = @SrcLot, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S = Status FROM #R; DROP TABLE #R;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachInElig] eligible pick succeeds (Status=1)', @Expected = N'1', @Actual = @SStr;
GO

-- =============================================
-- Test 2: ineligible source rejects (no eligibility path at a different Cell)
-- =============================================
-- A second Machining-In Cell where the machined Item is NOT eligible. We place an
-- eligible source LOT there first (Lot_Create needs eligibility), so we add a
-- TEMPORARY Direct eligibility for the SOURCE Item only, create the LOT, then
-- remove it so the pick's eligibility check (which evaluates the source Item) fails.
DECLARE @Cell2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-MIN');
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@SrcItem, @Cell2, 0, @Now);
DECLARE @TmpEl BIGINT = SCOPE_IDENTITY();

DECLARE @SrcLot2 BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell2, @PieceCount = 30, @AppUserId = 1, @LotName = N'P5T-SRC-020B';
SELECT @SrcLot2 = NewId FROM #C2; DROP TABLE #C2;

-- remove the temp eligibility so the source is no longer eligible at Cell2
DELETE FROM Parts.ItemLocation WHERE Id = @TmpEl;

DECLARE @S2 BIT, @Msg2 NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R2 EXEC Workorder.MachiningIn_PickAndConsume @SourceLotId = @SrcLot2, @CellLocationId = @Cell2, @AppUserId = 1;
SELECT @S2 = Status, @Msg2 = Message FROM #R2; DROP TABLE #R2;
DECLARE @S2cond BIT = CASE WHEN @S2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInElig] ineligible source rejected', @Condition = @S2cond;
EXEC test.Assert_Contains @TestName = N'[MachInElig] rejection cites eligibility', @HaystackStr = @Msg2, @NeedleStr = N'eligible';
GO

-- ---- cleanup ----
DELETE ce FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId WHERE l.LotName LIKE N'P5T%';
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE ac FROM Lots.LotAttributeChange ac INNER JOIN Lots.Lot l ON l.Id = ac.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
GO

EXEC test.EndTestFile;
GO
