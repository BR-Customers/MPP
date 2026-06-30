-- =============================================
-- File:         0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  A rework LOT routed back to a Machining Cell from the Sort Cage
--               (Phase 7) flows through the SAME MachiningIn pick + rename with no
--               special handling (spec sec "Rework LOTs"):
--                 - the rework LOT (CurrentLocationId = Machining Cell) appears in
--                   that Cell's FIFO queue (Lot_GetWipQueueByLocation)
--                 - MachiningIn_PickAndConsume succeeds: consumes the rework LOT,
--                   produces a new machined LOT under the same machined Item
--                 - genealogy Consumption edge rework->machined written
--               Fixture reuses the P5-CAST-TEST / P5-MACH-TEST single-line BOM +
--               eligibility (machined Item eligible at MA1-COMPBR-MIN). The "rework"
--               nature is purely that the source LOT's CurrentLocationId is the
--               Machining Cell -- the proc treats it identically to any queue entry.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql';
GO

-- ---- fixture (idempotent; mirrors 010) ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P5-CAST-TEST', N'Phase5 test cast/trim part', 1, @Now, 1);
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @MachItem AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt) VALUES (@MachItem, 1, '2026-01-01', '2026-01-01', NULL, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @SrcItem, 1.0, 1, 1);
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

-- ====================================================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

-- a "rework" LOT: a cast/trim-Item LOT whose CurrentLocationId is the Machining Cell.
DECLARE @Rework BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 18, @AppUserId = 1, @LotName = N'P5T-REWORK-090';
SELECT @Rework = NewId FROM #C; DROP TABLE #C;

-- rework LOT appears in the Cell's FIFO queue
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), HasRenameBom BIT);
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Cell;
DECLARE @InQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Rework);
DROP TABLE #Q;
EXEC test.Assert_IsEqual @TestName = N'[Rework] rework LOT visible in Cell FIFO queue', @Expected = N'1', @Actual = @InQ;

-- flows through MachiningIn pick with no special handling
DECLARE @S BIT, @MachLot BIGINT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningIn_PickAndConsume @SourceLotId = @Rework, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S = Status, @MachLot = NewId FROM #R; DROP TABLE #R;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Rework] MachiningIn pick succeeds for rework LOT', @Expected = N'1', @Actual = @SStr;

-- produces a machined LOT under the machined Item
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @ProducedItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @MachLot);
DECLARE @MachItemStr NVARCHAR(20) = CAST(@MachItem AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rework] produced LOT under the machined Item', @Expected = @MachItemStr, @Actual = @ProducedItem;

-- genealogy edge rework->machined
DECLARE @EdgeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ParentLotId = @Rework AND ChildLotId = @MachLot AND RelationshipTypeId = 3);
EXEC test.Assert_IsEqual @TestName = N'[Rework] genealogy edge rework->machined written', @Expected = N'1', @Actual = @EdgeCnt;

-- rework LOT closed
DECLARE @ReworkStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Rework);
EXEC test.Assert_IsEqual @TestName = N'[Rework] rework LOT closed after pick', @Expected = N'Closed', @Actual = @ReworkStatus;
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
