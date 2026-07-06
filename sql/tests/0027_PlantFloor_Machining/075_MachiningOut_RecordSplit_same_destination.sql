-- =============================================
-- File:         0027_PlantFloor_Machining/075_MachiningOut_RecordSplit_same_destination.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Legitimate edge case for MachiningOut_RecordSplit: N children all
--               routed to the SAME destination (e.g. 3-way 20/20/20 -> one
--               Assembly-finished Cell):
--                 - Status=1; three child rows; all three at the same destination
--                 - distinct child LotNames ('-NN' ordinals)
--                 - parent Closed
--               Fixture: P5-MACH-TEST; parent at MA1-FPRPY-MOUT; all 3 to
--               MA1-FPRPY-AFIN.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/075_MachiningOut_RecordSplit_same_destination.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Parent AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Parent, 0, @Now);
GO

-- ---- LOT cleanup ----
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
DECLARE @Dest BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');

-- 60-pc parent, extracted one 20-pc sublot per call, THREE calls, all to the same
-- destination. Each call mints the next '-NN' ordinal; parent Closes on the third.
DECLARE @ParentLot BIGINT, @ParentName NVARCHAR(50);
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Parent, @PieceCount = 60, @AppUserId = 1, @LotName = N'P5T-SPL-SAME';
SELECT @ParentLot = NewId, @ParentName = MintedLotName FROM #C; DROP TABLE #C;

DECLARE @D NVARCHAR(20) = CAST(@Dest AS NVARCHAR(20));
DECLARE @Json1 NVARCHAR(MAX) = N'[{"pieceCount":20,"destinationLocationId":' + @D + N'}]';

-- ---- Call 1 -> parent Good @40 ----
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R1 EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @ParentLot, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json1, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT TOP 1 CAST(Status AS NVARCHAR(10)) FROM #R1); DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName = N'[MachSplitSame] call-1 Status is 1', @Expected = N'1', @Actual = @S1;
DECLARE @Pc1 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitSame] parent 40 after call-1', @Expected = N'40', @Actual = @Pc1;

-- ---- Call 2 -> parent Good @20 ----
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R2 EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @ParentLot, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json1, @AppUserId = 1;
DROP TABLE #R2;
DECLARE @Pc2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitSame] parent 20 after call-2', @Expected = N'20', @Actual = @Pc2;

-- ---- Call 3 -> parent Closed @0 ----
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R3 EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @ParentLot, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json1, @AppUserId = 1;
DROP TABLE #R3;

-- three children, all at the same destination
DECLARE @ChildRows INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ParentLotId = @ParentLot);
EXEC test.Assert_RowCount @TestName = N'[MachSplitSame] three children minted', @ExpectedCount = 3, @ActualCount = @ChildRows;
DECLARE @AtDest INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ParentLotId = @ParentLot AND CurrentLocationId = @Dest);
EXEC test.Assert_RowCount @TestName = N'[MachSplitSame] all three children at the same destination', @ExpectedCount = 3, @ActualCount = @AtDest;

-- sequential '-01','-02','-03' ordinals
DECLARE @SeqNames INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ParentLotId = @ParentLot
    AND LotName IN (@ParentName + N'-01', @ParentName + N'-02', @ParentName + N'-03'));
EXEC test.Assert_RowCount @TestName = N'[MachSplitSame] children named -01/-02/-03', @ExpectedCount = 3, @ActualCount = @SeqNames;

-- parent Closed after the final extraction
DECLARE @ParentStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @ParentLot);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitSame] parent Closed', @Expected = N'Closed', @Actual = @ParentStatus;
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
