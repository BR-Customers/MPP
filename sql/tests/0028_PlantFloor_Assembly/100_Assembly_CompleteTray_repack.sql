-- =============================================
-- File:         0028_PlantFloor_Assembly/100_Assembly_CompleteTray_repack.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-06
-- Description:  Pass-through repack. A finished good with NO published BOM is a
--               part MPP receives finished, inspects and repackages under the same
--               part number. Workorder.Assembly_CompleteTray must close a tray for
--               it by consuming RECEIVED-origin LOTs of that same part at the line
--               (Consumption genealogy, RelationshipTypeId = 3), and
--               Parts.Item_ListEligibleFinishedGoodsRanked must offer it.
--               Cases:
--                 1) no received stock -> Status 0, nothing minted;
--                 2) happy path: tray LOT minted (Manufactured, BomId NULL), the
--                    received LOT drawn down, event + edge + closure written;
--                 3) the tray LOT just minted is NOT repack stock (it is
--                    Manufactured-origin) -> a second tray is short;
--                 4) FIFO across two received LOTs (Received + ReceivedOffsite);
--                 5) a HELD received LOT is not counted;
--                 6) the ranked list offers the part, satisfied only with stock.
--               Fixture cell: MA1-COMPBR-AOUT (assembly-out).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/100_Assembly_CompleteTray_repack.sql';
GO

-- ---- cleanup (FK-safe) ----
DECLARE @FgC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DELETE ce FROM Workorder.ConsumptionEvent ce WHERE ce.ProducedItemId = @FgC OR ce.ConsumedItemId = @FgC;
DELETE he FROM Quality.HoldEvent he INNER JOIN Lots.Lot l ON l.Id = he.LotId WHERE l.ItemId = @FgC;
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId = @FgC;
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId = @FgC;
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @FgC;
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @FgC;
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @FgC;
DELETE FROM Lots.Container WHERE ItemId = @FgC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @FgC;
DELETE FROM Lots.Lot WHERE ItemId = @FgC;
GO

-- ---- fixture: a FinishedGood with a pack-out, eligible at the cell, and NO BOM ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @FgType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@FgType, N'P6-RPK-FG', N'100 repack finished good', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- container config: 4 trays x 24 parts, ByCount (4 so the over-fill guard never fires here)
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Fg, 4, 24, 0, N'ByCount', @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Fg AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Cell, 0, @Now);

DECLARE @Boms NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.Bom WHERE ParentItemId = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] fixture: the finished good has no BOM', @Expected = N'0', @Actual = @Boms;
GO

-- =============================================
-- Test 1: no received stock -> refused, nothing minted. Ranked list offers the part unsatisfied.
-- =============================================
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Repack] no received stock -> Status 0', @Expected = N'0', @Actual = @S;
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_Contains @TestName = N'[Repack] message names the missing received stock', @HaystackStr = @M, @NeedleStr = N'received stock';
EXEC test.Assert_Contains @TestName = N'[Repack] message gives need and have', @HaystackStr = @M, @NeedleStr = N'need 24, have 0';
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] nothing minted', @Expected = N'0', @Actual = @N;

DECLARE @L TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended INT);
INSERT INTO @L EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Cell;
DECLARE @Listed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] ranked list offers a no-BOM finished good', @Expected = N'1', @Actual = @Listed;
DECLARE @Sat0 NVARCHAR(10) = (SELECT CAST(LinesSatisfied AS NVARCHAR(10)) FROM @L WHERE Id = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] ranked: not satisfied without received stock', @Expected = N'0', @Actual = @Sat0;
GO

-- =============================================
-- Test 2: happy path -- one Received LOT of 30, tray of 24.
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, VendorLotNumber, CreatedByUserId, CreatedAt)
VALUES (N'STG-100R1', @Fg, @Received, 1, 30, 30, @Cell, N'VND-100', 1, @Now);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName = N'STG-100R1';

DECLARE @L TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended INT);
INSERT INTO @L EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Cell;
DECLARE @Sat1 NVARCHAR(10) = (SELECT CAST(LinesSatisfied AS NVARCHAR(10)) FROM @L WHERE Id = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] ranked: satisfied once received stock is at the line', @Expected = N'1', @Actual = @Sat1;

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
DECLARE @Msg NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Repack] tray closes from received stock (Status 1)', @Expected = N'1', @Actual = @S;

DECLARE @Tray BIGINT = (SELECT FinishedGoodLotId FROM @R);
DECLARE @R1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-100R1');
DECLARE @Shape NVARCHAR(100) = (SELECT o.Code + N'/' + CAST(l.PieceCount AS NVARCHAR(10)) + N'/' + ISNULL(CAST(l.BomId AS NVARCHAR(20)), N'nobom')
                                FROM Lots.Lot l INNER JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId WHERE l.Id = @Tray);
EXEC test.Assert_IsEqual @TestName = N'[Repack] tray LOT is Manufactured, 24 pcs, no BOM', @Expected = N'Manufactured/24/nobom', @Actual = @Shape;
DECLARE @Left NVARCHAR(40) = (SELECT CAST(PieceCount AS NVARCHAR(10)) + N'/' + CAST(InventoryAvailable AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @R1);
EXEC test.Assert_IsEqual @TestName = N'[Repack] received LOT drawn down to 6', @Expected = N'6/6', @Actual = @Left;
DECLARE @Ev NVARCHAR(40) = (SELECT CAST(SUM(PieceCount) AS NVARCHAR(10)) + N'/' + CAST(COUNT(*) AS NVARCHAR(10))
                            FROM Workorder.ConsumptionEvent
                            WHERE ProducedLotId = @Tray AND SourceLotId = @R1 AND ConsumedItemId = @Fg AND ProducedItemId = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] one consumption event of 24, same part both sides', @Expected = N'24/1', @Actual = @Ev;
DECLARE @Edge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy
                              WHERE ParentLotId = @R1 AND ChildLotId = @Tray AND RelationshipTypeId = 3 AND PieceCount = 24);
EXEC test.Assert_IsEqual @TestName = N'[Repack] Consumption genealogy edge received -> tray', @Expected = N'1', @Actual = @Edge;
DECLARE @Clos NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogyClosure
                              WHERE AncestorLotId = @R1 AND DescendantLotId = @Tray AND Depth = 1);
EXEC test.Assert_IsEqual @TestName = N'[Repack] closure links the received LOT to the tray', @Expected = N'1', @Actual = @Clos;
GO

-- =============================================
-- Test 3: the minted tray LOT is not repack stock. 6 received left + 24 in the tray LOT
--         must read as "have 6", and the tray LOT must stay untouched.
-- =============================================
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Repack] second tray is short (Status 0)', @Expected = N'0', @Actual = @S;
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_Contains @TestName = N'[Repack] the minted tray LOT is not counted as stock', @HaystackStr = @M, @NeedleStr = N'need 24, have 6';
DECLARE @TrayPcs NVARCHAR(40) = (SELECT CAST(SUM(l.PieceCount) AS NVARCHAR(10)) + N'/' + CAST(COUNT(*) AS NVARCHAR(10))
                                 FROM Lots.Lot l INNER JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
                                 WHERE l.ItemId = @Fg AND o.Code = N'Manufactured');
EXEC test.Assert_IsEqual @TestName = N'[Repack] still one tray LOT, still 24 pcs', @Expected = N'24/1', @Actual = @TrayPcs;
GO

-- =============================================
-- Test 4 + 5: FIFO across two received LOTs; a HELD received LOT is skipped.
--   R1 has 6. Add RH (held, 50, oldest-but-one) and R2 (ReceivedOffsite, 18).
--   A tray of 24 must take 6 from R1 + 18 from R2 and leave RH alone.
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Offsite  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'ReceivedOffsite');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'STG-100RH', @Fg, @Received, 1, 50, 50, @Cell, 1, DATEADD(SECOND, 1, @Now)),
       (N'STG-100R2', @Fg, @Offsite,  1, 18, 18, @Cell, 1, DATEADD(SECOND, 2, @Now));
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName IN (N'STG-100RH', N'STG-100R2');
DECLARE @RH BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-100RH');
DECLARE @HR TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HR EXEC Quality.Hold_Place @LotId = @RH, @HoldTypeCodeId = 1, @Reason = N'100 fixture hold', @AppUserId = 1;

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @S NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Repack] tray closes across two received LOTs (Status 1)', @Expected = N'1', @Actual = @S;

DECLARE @Tray BIGINT = (SELECT FinishedGoodLotId FROM @R);
DECLARE @Split NVARCHAR(100) = (
    SELECT STRING_AGG(l.LotName + N'=' + CAST(ce.PieceCount AS NVARCHAR(10)), N',') WITHIN GROUP (ORDER BY l.LotName)
    FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId WHERE ce.ProducedLotId = @Tray);
EXEC test.Assert_IsEqual @TestName = N'[Repack] FIFO: 6 from the older LOT, 18 from the newer, none from the held one',
    @Expected = N'STG-100R1=6,STG-100R2=18', @Actual = @Split;
DECLARE @Closed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                                WHERE l.LotName IN (N'STG-100R1', N'STG-100R2') AND sc.Code = N'Closed' AND l.PieceCount = 0);
EXEC test.Assert_IsEqual @TestName = N'[Repack] both drained received LOTs are Closed', @Expected = N'2', @Actual = @Closed;
DECLARE @Held NVARCHAR(40) = (SELECT sc.Code + N'/' + CAST(l.PieceCount AS NVARCHAR(10)) FROM Lots.Lot l
                              INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @RH);
EXEC test.Assert_IsEqual @TestName = N'[Repack] held received LOT untouched', @Expected = N'Hold/50', @Actual = @Held;
DECLARE @Trays NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ContainerTray tr
                               INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Repack] two trays in the one open container', @Expected = N'2', @Actual = @Trays;
GO

-- ---- cleanup ----
DECLARE @FgC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-RPK-FG');
DELETE ce FROM Workorder.ConsumptionEvent ce WHERE ce.ProducedItemId = @FgC OR ce.ConsumedItemId = @FgC;
DELETE he FROM Quality.HoldEvent he INNER JOIN Lots.Lot l ON l.Id = he.LotId WHERE l.ItemId = @FgC;
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId = @FgC;
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId = @FgC;
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @FgC;
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @FgC;
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @FgC;
DELETE FROM Lots.Container WHERE ItemId = @FgC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @FgC;
DELETE FROM Lots.Lot WHERE ItemId = @FgC;
DELETE FROM Parts.ItemLocation WHERE ItemId = @FgC;
DELETE FROM Parts.ContainerConfig WHERE ItemId = @FgC;
GO

EXEC test.EndTestFile;
GO
