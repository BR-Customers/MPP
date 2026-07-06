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
-- Extract-one across TWO calls: 48-pc parent -> extract 24 (parent stays open @24)
-- -> extract the remaining 24 (parent Closes). Each call mints the next '-NN' sublot.
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

-- ---- Call 1: extract 24 -> Dest1 (parent should stay open with 24 remaining) ----
DECLARE @Json1 NVARCHAR(MAX) = N'[{"pieceCount":24,"destinationLocationId":' + CAST(@Dest1 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R1 EXEC Workorder.MachiningOut_RecordSplit
    @ParentLotId = @ParentLot, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json1, @AppUserId = 1;

DECLARE @S1 NVARCHAR(10) = (SELECT TOP 1 CAST(Status AS NVARCHAR(10)) FROM #R1);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] call-1 Status is 1', @Expected = N'1', @Actual = @S1;
DECLARE @Prod1 NVARCHAR(20) = (SELECT TOP 1 CAST(ProductionEventId AS NVARCHAR(20)) FROM #R1);
EXEC test.Assert_IsNotNull @TestName = N'[MachSplit] call-1 ProductionEventId returned', @Value = @Prod1;

-- parent still OPEN (Good) at 24 pcs after the partial extraction
DECLARE @PStatus1 NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] parent stays Good after call-1', @Expected = N'Good', @Actual = @PStatus1;
DECLARE @PPc1 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] parent remainder 24 after call-1', @Expected = N'24', @Actual = @PPc1;

-- child -01 minted at Dest1
DECLARE @Child1 BIGINT = (SELECT TOP 1 ChildLotId FROM #R1 WHERE ChildLotId IS NOT NULL);
DECLARE @Child1Name NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @Child1);
DECLARE @Expect1 NVARCHAR(50) = @ParentName + N'-01';
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] first child is -01 ordinal', @Expected = @Expect1, @Actual = @Child1Name;
DROP TABLE #R1;

-- ---- Call 2: extract the remaining 24 -> Dest2 (parent should Close) ----
DECLARE @Json2 NVARCHAR(MAX) = N'[{"pieceCount":24,"destinationLocationId":' + CAST(@Dest2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R2 EXEC Workorder.MachiningOut_RecordSplit
    @ParentLotId = @ParentLot, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json2, @AppUserId = 1;

DECLARE @S2 NVARCHAR(10) = (SELECT TOP 1 CAST(Status AS NVARCHAR(10)) FROM #R2);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] call-2 Status is 1', @Expected = N'1', @Actual = @S2;

-- child -02 minted at Dest2 (next ordinal)
DECLARE @Child2 BIGINT = (SELECT TOP 1 ChildLotId FROM #R2 WHERE ChildLotId IS NOT NULL);
DECLARE @Child2Name NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @Child2);
DECLARE @Expect2 NVARCHAR(50) = @ParentName + N'-02';
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] second child is -02 ordinal', @Expected = @Expect2, @Actual = @Child2Name;
DROP TABLE #R2;

-- parent now Closed (remainder zeroed)
DECLARE @PStatus2 NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] parent Closed after final extraction', @Expected = N'Closed', @Actual = @PStatus2;
DECLARE @PPc2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplit] parent PieceCount 0 after final extraction', @Expected = N'0', @Actual = @PPc2;

-- ---- aggregate assertions across both extractions ----
-- both children carry the machined Item
DECLARE @ChildWrongItem INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ParentLotId = @ParentLot AND ItemId <> @MachItem);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] children carry the machined Item', @ExpectedCount = 0, @ActualCount = @ChildWrongItem;

-- two Split edges parent->child (RelationshipTypeId=1)
DECLARE @EdgeCnt INT = (SELECT COUNT(*) FROM Lots.LotGenealogy WHERE ParentLotId = @ParentLot AND RelationshipTypeId = 1);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] two Split genealogy edges', @ExpectedCount = 2, @ActualCount = @EdgeCnt;

-- two closure rows parent->child at depth 1
DECLARE @ClosCnt INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @ParentLot AND Depth = 1);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] two closure rows parent->child depth=1', @ExpectedCount = 2, @ActualCount = @ClosCnt;

-- each child at its destination (CurrentLocationId matches its call's dest)
DECLARE @Misplaced INT = (SELECT COUNT(*) FROM Lots.Lot WHERE Id = @Child1 AND CurrentLocationId <> @Dest1)
                       + (SELECT COUNT(*) FROM Lots.Lot WHERE Id = @Child2 AND CurrentLocationId <> @Dest2);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] each child at its destination', @ExpectedCount = 0, @ActualCount = @Misplaced;

-- child-1 visible in Dest1 FIFO queue
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), HasRenameBom BIT);
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Dest1;
DECLARE @InQ1 INT = (SELECT COUNT(*) FROM #Q WHERE Id = @Child1);
DROP TABLE #Q;
EXEC test.Assert_RowCount @TestName = N'[MachSplit] child visible in destination-1 FIFO queue', @ExpectedCount = 1, @ActualCount = @InQ1;

-- audit: two 'Lot'-entity MachiningOutSubLotSplit events route to Lots.LotEventLog (B7).
DECLARE @AudCnt INT = (SELECT COUNT(*) FROM Lots.LotEventLog le INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId WHERE et.Code = N'MachiningOutSubLotSplit' AND le.EntityId = @ParentLot);
EXEC test.Assert_RowCount @TestName = N'[MachSplit] two MachiningOutSubLotSplit audits in LotEventLog', @ExpectedCount = 2, @ActualCount = @AudCnt;
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
