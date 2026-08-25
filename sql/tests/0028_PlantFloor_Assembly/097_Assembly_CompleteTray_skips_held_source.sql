-- =============================================
-- File:         0028_PlantFloor_Assembly/097_Assembly_CompleteTray_skips_held_source.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-24
-- Description:  Workorder.Assembly_CompleteTray must exclude BLOCKED source LOTs
--               (BlocksProduction=1 -- Hold/Scrap) from its FIFO consume, matching
--               every sibling consume proc (MachiningOut_Mint, LotGenealogy_
--               RecordConsumption). Before this fix the consume filtered <> Closed
--               ONLY, so a held component LOT was still counted as available AND
--               consumed -- letting a failed/held part be shipped by assembly-out /
--               third-party check-out. Two cases:
--                 1) a held LOT is NOT counted (Status 0 insufficient) and NOT
--                    consumed (unchanged pcs/avail, still Hold);
--                 2) FIFO SKIPS an older held LOT and consumes a newer Good LOT.
--               Fixture cell: MA1-COMPBR-AOUT (assembly-out).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/097_Assembly_CompleteTray_skips_held_source.sql';
GO

-- ---- cleanup (FK-safe: consumption -> holds -> genealogy/closure/movement/history -> trays -> container -> LOTs) ----
DECLARE @OutC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-OUT');
DELETE ce FROM Workorder.ConsumptionEvent ce
    WHERE ce.ProducedItemId = @OutC
       OR ce.ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-H');
DELETE he FROM Quality.HoldEvent he INNER JOIN Lots.Lot l ON l.Id = he.LotId WHERE l.LotName LIKE N'STG-097%';
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @OutC;
DELETE FROM Lots.Container WHERE ItemId = @OutC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE FROM Lots.Lot WHERE ItemId = @OutC OR LotName LIKE N'STG-097%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CTH-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CTH-OUT', N'097 finished good', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CTH-H')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CTH-H', N'097 component', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-OUT');
DECLARE @H BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-H');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- container config: 1 tray x 24 parts, ByCount
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 1, 24, 0, N'ByCount', @Now);

-- published BOM: OUT <- H x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @H, 1, 1, 1);
END

-- FG item eligible at the cell
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Out AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Out, @Cell, 0, @Now);

-- staged component stock at the cell: ONE LOT of exactly 24 (older), which we then HOLD.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-097H1', @H, 1, 1, 24, 24, @Cell, 1, @Now);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName = N'STG-097H1'
  AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure c WHERE c.AncestorLotId = Lots.Lot.Id AND c.DescendantLotId = Lots.Lot.Id);

-- place the component LOT on Hold (HoldTypeCode 1 = Quality) -> LotStatusId 2 (BlocksProduction=1)
DECLARE @H1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-097H1');
DECLARE @HR TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HR EXEC Quality.Hold_Place @LotId = @H1, @HoldTypeCodeId = 1, @Reason = N'097 fixture hold', @AppUserId = 1;
GO

-- =============================================
-- Test 1: a HELD component LOT is not counted as available (Status 0) and is not consumed.
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R1 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;

DECLARE @S1 BIT = (SELECT Status FROM @R1);
DECLARE @S1cond BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[HeldSource] held-only stock rejected (Status 0)', @Condition = @S1cond;
DECLARE @M1 NVARCHAR(500) = (SELECT Message FROM @R1);
EXEC test.Assert_Contains @TestName = N'[HeldSource] insufficient-stock message (held not counted)', @HaystackStr = @M1, @NeedleStr = N'Insufficient component stock';

-- held LOT untouched: still 24 pcs, 24 available, still Hold
DECLARE @H1Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-097H1');
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] held LOT PieceCount unchanged (24)', @Expected = N'24', @Actual = @H1Pc;
DECLARE @H1Av NVARCHAR(10) = (SELECT CAST(InventoryAvailable AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-097H1');
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] held LOT InventoryAvailable unchanged (24)', @Expected = N'24', @Actual = @H1Av;
DECLARE @H1Status NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'STG-097H1');
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] held LOT still Hold', @Expected = N'Hold', @Actual = @H1Status;
-- nothing minted
DECLARE @FgCount1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Out);
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] no FG LOT minted when only held stock present', @Expected = N'0', @Actual = @FgCount1;
GO

-- =============================================
-- Test 2: FIFO SKIPS the older held LOT and consumes a newer Good LOT.
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-OUT');
DECLARE @H BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-H');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Now2 DATETIME2(3) = DATEADD(SECOND, 10, SYSUTCDATETIME());

-- add a NEWER Good LOT of 24; the older STG-097H1 (24) is still on Hold.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-097H2', @H, 1, 1, 24, 24, @Cell, 1, @Now2);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName = N'STG-097H2'
  AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure c WHERE c.AncestorLotId = Lots.Lot.Id AND c.DescendantLotId = Lots.Lot.Id);

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R2 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;

DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] Good LOT satisfies the tray (Status 1)', @Expected = N'1', @Actual = @S2;
DECLARE @Fg2 BIGINT = (SELECT FinishedGoodLotId FROM @R2);

-- the Good LOT was drained + Closed; the held LOT stays untouched
DECLARE @H2Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-097H2');
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] Good LOT drained to 0', @Expected = N'0', @Actual = @H2Pc;
DECLARE @H2Status NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'STG-097H2');
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] Good LOT Closed after full consume', @Expected = N'Closed', @Actual = @H2Status;
DECLARE @H1Pc2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-097H1');
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] held LOT STILL untouched after Good consume (24)', @Expected = N'24', @Actual = @H1Pc2;

-- consumption sourced ONLY the Good LOT, never the held one
DECLARE @HeldId BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-097H1');
DECLARE @GoodId BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-097H2');
DECLARE @FromHeld NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Fg2 AND SourceLotId = @HeldId);
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] no consumption sourced the held LOT', @Expected = N'0', @Actual = @FromHeld;
DECLARE @FromGood NVARCHAR(10) = (SELECT CAST(ISNULL(SUM(PieceCount),0) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Fg2 AND SourceLotId = @GoodId);
EXEC test.Assert_IsEqual @TestName = N'[HeldSource] 24 consumed from the Good LOT', @Expected = N'24', @Actual = @FromGood;
GO

-- ---- cleanup ----
DECLARE @OutC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-OUT');
DELETE ce FROM Workorder.ConsumptionEvent ce
    WHERE ce.ProducedItemId = @OutC
       OR ce.ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CTH-H');
DELETE he FROM Quality.HoldEvent he INNER JOIN Lots.Lot l ON l.Id = he.LotId WHERE l.LotName LIKE N'STG-097%';
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @OutC;
DELETE FROM Lots.Container WHERE ItemId = @OutC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @OutC OR l.LotName LIKE N'STG-097%';
DELETE FROM Lots.Lot WHERE ItemId = @OutC OR LotName LIKE N'STG-097%';
GO

EXEC test.EndTestFile;
GO
