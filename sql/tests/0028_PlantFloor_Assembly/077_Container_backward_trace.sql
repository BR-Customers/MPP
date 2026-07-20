-- =============================================
-- File:         0028_PlantFloor_Assembly/077_Container_backward_trace.sql
-- Description:  End-to-end Honda backward trace (Arc 2 Phase 6 / FDS-05-017, FDS-06-021),
--               reconciled to the finished-good-LOT model (Spec 2). Assembly now MINTS a
--               finished-good LOT (tray = LOT) via Workorder.Assembly_CompleteTray, which
--               consumes the machined LOT INTO the FG LOT (ConsumptionEvent.ProducedLotId =
--               FG LOT). The machining edge mirrors what MachiningIn_PickAndConsume writes
--               (SourceLot = cast -> ProducedLot = machined). The point: the two edges
--               COMPOSE on the same machined LOT, so a walk FG-LOT -> machined -> cast
--               reaches the original casting.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/077_Container_backward_trace.sql';
GO

-- ---- cleanup (FK-safe) ----
DECLARE @AsmC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-ASM');
DELETE FROM Workorder.ConsumptionEvent WHERE ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-CAST', N'P7-TRACE-MACH'))
    OR ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-MACH', N'P7-TRACE-ASM'));
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @AsmC;
DELETE FROM Lots.Container WHERE ItemId = @AsmC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @AsmC OR LotName IN (N'TRC-CAST', N'TRC-MACH'));
DELETE FROM Lots.Lot WHERE ItemId = @AsmC OR LotName IN (N'TRC-CAST', N'TRC-MACH');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-TRACE-CAST') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P7-TRACE-CAST', N'Trace test casting', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-TRACE-MACH') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P7-TRACE-MACH', N'Trace test machined', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-TRACE-ASM') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (4, N'P7-TRACE-ASM', N'Trace test assembly', 1, @Now, 1);
DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-CAST');
DECLARE @Mach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-MACH');
DECLARE @Asm  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-ASM');

-- assembly BOM: P7-TRACE-ASM <- P7-TRACE-MACH x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Asm AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Asm, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Mach, 1, 1, 1);
END
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Asm AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Asm, 1, 24, 0, N'ByCount', @Now);

DECLARE @MachCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');     -- where casting was machined
DECLARE @AsmCell  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');  -- assembly cell

-- FG item eligible at the assembly cell (Assembly_CompleteTray mirrors Lot_Create eligibility)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Asm AND LocationId = @AsmCell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Asm, @AsmCell, 0, @Now);

-- the cast LOT (machining input) and the machined LOT (assembly input, staged at the cell
-- with InventoryAvailable + a genealogy closure self-row so consumption can propagate)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'TRC-CAST', @Cast, 1, 1, 48, 48, @MachCell, 1, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'TRC-MACH', @Mach, 1, 1, 48, 48, @AsmCell, 1, @Now);
DECLARE @CastLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TRC-CAST');
DECLARE @MachLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TRC-MACH');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@CastLot, @CastLot, 0), (@MachLot, @MachLot, 0);

-- machining edge (mirror of MachiningIn_PickAndConsume): cast LOT consumed -> machined LOT produced
INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, ConsumedAt)
VALUES (@CastLot, @MachLot, @Cast, @Mach, 48, @MachCell, 1, @Now);

-- assembly edge: Assembly_CompleteTray mints the FG LOT, consuming the machined LOT into it
DECLARE @CT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @CT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Asm, @PieceCount = 24, @CellLocationId = @AsmCell, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CT);
EXEC test.Assert_IsEqual @TestName = N'[Trace] assembly tray completion Status 1', @Expected = N'1', @Actual = @S;
DECLARE @FgLot BIGINT = (SELECT FinishedGoodLotId FROM @CT);

-- assembly edge present: machined LOT consumed INTO the FG LOT (ProducedLotId = FG LOT)
DECLARE @AsmEdge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @FgLot AND SourceLotId = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[Trace] FG LOT <- machined LOT consumption edge', @Expected = N'1', @Actual = @AsmEdge;
-- machining edge present: cast LOT consumed into the machined LOT
DECLARE @MachEdge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @MachLot AND SourceLotId = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[Trace] machined LOT <- cast LOT consumption edge', @Expected = N'1', @Actual = @MachEdge;

-- composition: walking FG LOT -> assembly edge -> machined -> machining edge -> cast reaches TRC-CAST
DECLARE @Reaches NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.ConsumptionEvent a
    INNER JOIN Workorder.ConsumptionEvent m ON m.ProducedLotId = a.SourceLotId
    INNER JOIN Lots.Lot c ON c.Id = m.SourceLotId
    WHERE a.ProducedLotId = @FgLot AND c.LotName = N'TRC-CAST');
EXEC test.Assert_IsEqual @TestName = N'[Trace] backward walk FG LOT -> machined -> cast reaches the cast LOT', @Expected = N'1', @Actual = @Reaches;

-- closure also links the cast LOT as an ancestor of the FG LOT (genealogy composes)
DECLARE @ClosReach NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @MachLot AND DescendantLotId = @FgLot);
EXEC test.Assert_IsEqual @TestName = N'[Trace] closure links machined LOT -> FG LOT', @Expected = N'1', @Actual = @ClosReach;
GO

-- ---- cleanup ----
DECLARE @AsmC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-ASM');
DELETE FROM Workorder.ConsumptionEvent WHERE ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-CAST', N'P7-TRACE-MACH'))
    OR ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-MACH', N'P7-TRACE-ASM'));
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @AsmC;
DELETE FROM Lots.Container WHERE ItemId = @AsmC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @AsmC OR l.LotName IN (N'TRC-CAST', N'TRC-MACH');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @AsmC OR LotName IN (N'TRC-CAST', N'TRC-MACH'));
DELETE FROM Lots.Lot WHERE ItemId = @AsmC OR LotName IN (N'TRC-CAST', N'TRC-MACH');
GO

EXEC test.EndTestFile;
GO
