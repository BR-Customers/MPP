-- =============================================
-- File:         0027_PlantFloor_Machining/010_MachiningIn_PickAndConsume_happy.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Happy path for Workorder.MachiningIn_PickAndConsume (Arc 2 Phase 5
--               Machining IN; FDS-05-033). A whole cast/trim LOT in a Machining
--               Cell's FIFO queue is picked + renamed via the machined Item's
--               single-line BOM:
--                 - Status=1; NewId (machined LOT) + machined LotName returned
--                 - machined LOT carries the MACHINED Item, Manufactured origin
--                 - ConsumptionEvent row for the source -> machined exists
--                 - LotGenealogy Consumption edge source -> machined exists
--                 - checkpoint MachiningIn ProductionEvent written
--                 - source LOT now Closed
--                 - MachiningInPicked audit in OperationLog
--               Fixture: dedicated Phase-5 test items P5-CAST-TEST (source) +
--               P5-MACH-TEST (machined), a published single-line BOM
--               (machined <- source @ QtyPer 1), machined Item eligible at the
--               Machining-In Cell MA1-COMPBR-MIN (so the source resolves BomDerived).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/010_MachiningIn_PickAndConsume_happy.sql';
GO

-- ====================================================================
-- Shared fixture builder (idempotent): items + single-line BOM + eligibility.
-- ====================================================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

-- source (cast/trim) Item
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P5-CAST-TEST', N'Phase5 test cast/trim part', 48, NULL, 1, @Now, 1);
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');

-- machined Item
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 24, NULL, 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');

-- single-line published BOM: machined <- source @ QtyPer 1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @MachItem AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (@MachItem, 1, '2026-01-01', '2026-01-01', NULL, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
    VALUES (@BomId, @SrcItem, 1.0, 1, 1);
END

-- machined Item eligible at the Machining-In Cell (so source resolves BomDerived)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
    VALUES (@MachItem, @Cell, 0, @Now);
GO

-- ---- fixture LOT cleanup (re-runnable) ----
DELETE ce FROM Workorder.ConsumptionEvent ce
    INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId
    WHERE l.LotName LIKE N'P5T%';
DELETE pe FROM Workorder.ProductionEvent pe
    INNER JOIN Lots.Lot l ON l.Id = pe.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE g FROM Lots.LotGenealogy g
    INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE c FROM Lots.LotGenealogyClosure c
    INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE m FROM Lots.LotMovement m
    INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE h FROM Lots.LotStatusHistory h
    INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE ac FROM Lots.LotAttributeChange ac
    INNER JOIN Lots.Lot l ON l.Id = ac.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P5-CAST-TEST', N'P5-MACH-TEST'));
GO

-- ====================================================================
-- Test: pick + consume
-- ====================================================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

-- a whole cast/trim LOT sitting in the Machining Cell's FIFO queue.
-- (source Item is BomDerived-eligible at the Cell, so Lot_Create here succeeds.)
DECLARE @SrcLot BIGINT, @SrcName NVARCHAR(50);
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create
    @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell,
    @PieceCount = 40, @AppUserId = 1, @LotName = N'P5T-SRC-010';
SELECT @SrcLot = NewId, @SrcName = MintedLotName FROM #C; DROP TABLE #C;

DECLARE @SrcLotStr NVARCHAR(20) = CAST(@SrcLot AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[MachIn] fixture source LOT created', @Value = @SrcLotStr;

-- pick
DECLARE @S BIT, @MachLot BIGINT, @MachName NVARCHAR(50), @ConsId BIGINT, @ProdId BIGINT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningIn_PickAndConsume
    @SourceLotId = @SrcLot, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S = Status, @MachLot = NewId, @MachName = NewMachinedLotName, @ConsId = ConsumptionEventId, @ProdId = ProductionEventId FROM #R;
DROP TABLE #R;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @MachLotStr NVARCHAR(20) = CAST(@MachLot AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[MachIn] machined LOT NewId returned', @Value = @MachLotStr;
EXEC test.Assert_IsNotNull @TestName = N'[MachIn] machined LotName returned', @Value = @MachName;

-- machined LOT carries the machined Item + Manufactured origin
DECLARE @MachItemActual NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @MachLot);
DECLARE @MachItemExp NVARCHAR(20) = CAST(@MachItem AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] machined LOT carries the machined Item', @Expected = @MachItemExp, @Actual = @MachItemActual;

DECLARE @OriginCode NVARCHAR(20) = (SELECT ot.Code FROM Lots.Lot l INNER JOIN Lots.LotOriginType ot ON ot.Id = l.LotOriginTypeId WHERE l.Id = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] machined LOT origin is Manufactured', @Expected = N'Manufactured', @Actual = @OriginCode;

-- machined LOT piece count = source piece count (1-line BOM @ QtyPer 1)
DECLARE @MachPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] machined LOT piece count = source (40)', @Expected = N'40', @Actual = @MachPc;

-- ConsumptionEvent row exists
DECLARE @ConsCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @SrcLot AND ProducedLotId = @MachLot AND PieceCount = 40);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] ConsumptionEvent source->machined written', @Expected = N'1', @Actual = @ConsCnt;

-- LotGenealogy Consumption edge exists
DECLARE @EdgeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ParentLotId = @SrcLot AND ChildLotId = @MachLot AND RelationshipTypeId = 3);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LotGenealogy Consumption edge written', @Expected = N'1', @Actual = @EdgeCnt;

-- closure ancestor row source->machined at depth 1
DECLARE @ClosCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @SrcLot AND DescendantLotId = @MachLot AND Depth = 1);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] closure source->machined depth=1', @Expected = N'1', @Actual = @ClosCnt;

-- checkpoint MachiningIn ProductionEvent
DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    WHERE pe.Id = @ProdId AND pe.LotId = @MachLot AND ot.Code = N'MachiningIn');
EXEC test.Assert_IsEqual @TestName = N'[MachIn] checkpoint MachiningIn ProductionEvent written', @Expected = N'1', @Actual = @PeCnt;

-- source LOT now Closed
DECLARE @SrcStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @SrcLot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] source LOT closed', @Expected = N'Closed', @Actual = @SrcStatus;

-- audit: 'Lot'-entity events route to Lots.LotEventLog (B7), NOT Audit.OperationLog.
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog le
    INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
    WHERE et.Code = N'MachiningInPicked' AND le.EntityId = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] MachiningInPicked audit in LotEventLog', @Expected = N'1', @Actual = @AudCnt;
GO

EXEC test.EndTestFile;
GO
