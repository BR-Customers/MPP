-- =============================================
-- File:         0028_PlantFloor_Assembly/077_Container_backward_trace.sql
-- Description:  End-to-end Honda backward trace (Arc 2 Phase 6 / FDS-05-017, FDS-06-021):
--               a completed assembly container traces back through its per-tray
--               ConsumptionEvents to the machined LOT, and through the machining
--               ConsumptionEvent to the cast LOT. The assembly edge is produced by the
--               real ContainerTray_Close; the machining edge mirrors what
--               MachiningIn_PickAndConsume writes (SourceLot=cast -> ProducedLot=machined),
--               which is exercised directly in the 0027 suite. The point here is that the
--               two edges COMPOSE on the same machined LOT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/077_Container_backward_trace.sql';
GO

DELETE FROM Workorder.ConsumptionEvent WHERE ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-CAST', N'P7-TRACE-MACH'))
    OR ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-MACH', N'P7-TRACE-ASM'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P7-TRACE-ASM';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-ASM');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'TRC-CAST', N'TRC-MACH'));
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'TRC-CAST', N'TRC-MACH'));
DELETE FROM Lots.Lot WHERE LotName IN (N'TRC-CAST', N'TRC-MACH');
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
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Asm AND DeprecatedAt IS NULL);

DECLARE @MachCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');     -- where casting was machined
DECLARE @AsmCell  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');  -- assembly cell

-- the cast LOT (machining input) and the machined LOT (assembly input)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'TRC-CAST', @Cast, 1, 1, 48, @MachCell, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'TRC-MACH', @Mach, 1, 1, 48, @AsmCell, 1);
DECLARE @CastLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TRC-CAST');
DECLARE @MachLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TRC-MACH');

-- machining edge (mirror of MachiningIn_PickAndConsume): cast LOT consumed -> machined LOT produced
INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, ConsumedAt)
VALUES (@CastLot, @MachLot, @Cast, @Mach, 48, @MachCell, 1, @Now);

-- assembly edge: real ContainerTray_Close consumes the machined LOT into the container
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Asm, @ContainerConfigId = @Config, @CellLocationId = @AsmCell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 24, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @TC);
EXEC test.Assert_IsEqual @TestName = N'[Trace] assembly tray close Status 1', @Expected = N'1', @Actual = @S;

-- assembly edge present: machined LOT consumed into the container
DECLARE @AsmEdge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid AND SourceLotId = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[Trace] container <- machined LOT consumption edge', @Expected = N'1', @Actual = @AsmEdge;
-- machining edge present: cast LOT consumed into the machined LOT
DECLARE @MachEdge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @MachLot AND SourceLotId = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[Trace] machined LOT <- cast LOT consumption edge', @Expected = N'1', @Actual = @MachEdge;

-- composition: walking container -> assembly edge -> machined -> machining edge -> cast reaches TRC-CAST
DECLARE @Reaches NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.ConsumptionEvent a
    INNER JOIN Workorder.ConsumptionEvent m ON m.ProducedLotId = a.SourceLotId
    INNER JOIN Lots.Lot c ON c.Id = m.SourceLotId
    WHERE a.ProducedContainerId = @Cid AND c.LotName = N'TRC-CAST');
EXEC test.Assert_IsEqual @TestName = N'[Trace] backward walk container -> machined -> cast reaches the cast LOT', @Expected = N'1', @Actual = @Reaches;
GO

DELETE FROM Workorder.ConsumptionEvent WHERE ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-CAST', N'P7-TRACE-MACH'))
    OR ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P7-TRACE-MACH', N'P7-TRACE-ASM'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P7-TRACE-ASM';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-TRACE-ASM');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'TRC-CAST', N'TRC-MACH'));
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'TRC-CAST', N'TRC-MACH'));
DELETE FROM Lots.Lot WHERE LotName IN (N'TRC-CAST', N'TRC-MACH');
GO

EXEC test.EndTestFile;
GO
