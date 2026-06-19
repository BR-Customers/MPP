-- =============================================
-- File:         0027_PlantFloor_Machining/070_MachiningOut_RecordSplit.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Happy path for Workorder.MachiningOut_RecordSplit (sublotting line,
--               FDS-05-009). A machined LOT (48 pcs) is split 2-way (24/24) into two
--               destinations:
--                 - header Status=1; ProductionEventId returned
--                 - two child rows returned, each with the parent's MACHINED Item
--                 - LotGenealogy Split edges (parent->child x2) + closure rows
--                 - each child at its destination (LotMovement + CurrentLocationId)
--                 - parent Closed
--                 - each child visible in its destination FIFO queue
--                 - MachiningOutSubLotSplit audit in OperationLog
--               Fixture: P5-MACH-TEST machined Item; parent LOT at MA1-FPRPY-MOUT
--               (a sublotting Machining-OUT terminal); children routed to
--               MA1-FPRPY-AFIN + MA1-FP6NA-AFIN (Assembly-finished Cells).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/070_MachiningOut_RecordSplit.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
-- machined Item eligible at the parent (Machining-OUT) Cell so Lot_Create succeeds
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Parent AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Parent, 0, @Now);
GO

-- ---- LOT cleanup (parent + any prior children) ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE ac FROM Lots.LotAttributeChange ac INNER JOIN Lots.Lot l ON l.Id = ac.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-SPL%';
GO

-- ====================================================================
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Dest1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @Dest2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');

-- a machined parent LOT (48 pcs)
DECLARE @ParentLot BIGINT, @ParentName NVARCHAR(50);
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Parent, @PieceCount = 48, @AppUserId = 1, @LotName = N'P5T-SPL-PARENT';
SELECT @ParentLot = NewId, @ParentName = MintedLotName FROM #C; DROP TABLE #C;

DECLARE @Json NVARCHAR(MAX) = N'[{"pieceCount":24,"destinationLocationId":' + CAST(@Dest1 AS NVARCHAR(20)) + N'},{"pieceCount":24,"destinationLocationId":' + CAST(@Dest2 AS NVARCHAR(20)) + N'}]';

CREATE TABLE #R (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R EXEC Workorder.MachiningOut_RecordSplit
    @ParentLotId = @ParentLot, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json, @AppUserId = 1;

DECLARE @S BIT = (SELECT TOP 1 Status FROM #R);
DECLARE @ProdId BIGINT = (SELECT TOP 1 ProductionEventId FROM #R);
DECLARE @ChildRows INT = (SELECT COUNT(*) FROM #R WHERE ChildLotId IS NOT NULL);

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] header Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @ProdStr NVARCHAR(20) = CAST(@ProdId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[MachSplit] ProductionEventId returned', @Value = @ProdStr;

EXEC test.Assert_RowCount @TestName = N'[MachSplit] two child rows returned', @ExpectedCount = 2, @ActualCount = @ChildRows;

-- both children carry the machined Item
DECLARE @ChildWrongItem INT = (SELECT COUNT(*) FROM #R r INNER JOIN Lots.Lot l ON l.Id = r.ChildLotId WHERE r.ChildLotId IS NOT NULL AND l.ItemId <> @MachItem);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] children carry the machined Item', @ExpectedCount = 0, @ActualCount = @ChildWrongItem;

-- Split edges parent->child (RelationshipTypeId=1)
DECLARE @EdgeCnt INT = (SELECT COUNT(*) FROM Lots.LotGenealogy WHERE ParentLotId = @ParentLot AND RelationshipTypeId = 1 AND ChildLotId IN (SELECT ChildLotId FROM #R WHERE ChildLotId IS NOT NULL));
EXEC test.Assert_RowCount @TestName = N'[MachSplit] two Split genealogy edges', @ExpectedCount = 2, @ActualCount = @EdgeCnt;

-- closure rows parent->child at depth 1
DECLARE @ClosCnt INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @ParentLot AND Depth = 1 AND DescendantLotId IN (SELECT ChildLotId FROM #R WHERE ChildLotId IS NOT NULL));
EXEC test.Assert_RowCount @TestName = N'[MachSplit] two closure rows parent->child depth=1', @ExpectedCount = 2, @ActualCount = @ClosCnt;

-- each child at its destination (CurrentLocationId matches the JSON dest)
DECLARE @MisplacedChildren INT = (SELECT COUNT(*) FROM #R r INNER JOIN Lots.Lot l ON l.Id = r.ChildLotId WHERE r.ChildLotId IS NOT NULL AND l.CurrentLocationId <> r.DestinationLocationId);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] each child at its destination', @ExpectedCount = 0, @ActualCount = @MisplacedChildren;

-- each child has a placement LotMovement to its destination
DECLARE @ChildMoves INT = (SELECT COUNT(*) FROM #R r INNER JOIN Lots.LotMovement m ON m.LotId = r.ChildLotId AND m.ToLocationId = r.DestinationLocationId WHERE r.ChildLotId IS NOT NULL);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] each child placed via LotMovement', @ExpectedCount = 2, @ActualCount = @ChildMoves;

-- parent Closed
DECLARE @ParentStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] parent Closed', @Expected = N'Closed', @Actual = @ParentStatus;

-- each child visible in its destination FIFO queue
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3));
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Dest1;
DECLARE @InQ1 INT = (SELECT COUNT(*) FROM #Q q INNER JOIN #R r ON r.ChildLotId = q.Id WHERE r.DestinationLocationId = @Dest1);
DROP TABLE #Q;
EXEC test.Assert_RowCount @TestName = N'[MachSplit] child visible in destination-1 FIFO queue', @ExpectedCount = 1, @ActualCount = @InQ1;

-- audit: 'Lot'-entity events route to Lots.LotEventLog (B7), NOT Audit.OperationLog.
DECLARE @AudCnt INT = (SELECT COUNT(*) FROM Lots.LotEventLog le INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId WHERE et.Code = N'MachiningOutSubLotSplit' AND le.EntityId = @ParentLot);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] MachiningOutSubLotSplit audit in LotEventLog', @ExpectedCount = 1, @ActualCount = @AudCnt;

DROP TABLE #R;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE ac FROM Lots.LotAttributeChange ac INNER JOIN Lots.Lot l ON l.Id = ac.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-SPL%';
GO

EXEC test.EndTestFile;
GO
