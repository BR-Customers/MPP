-- =============================================
-- File: 0056_CrtValidation/030_CompleteTray_marks_crt.sql
-- Desc: Assembly_CompleteTray mints the FG LOT with CrtActive = 1 when the
--       terminal has CrtEnabled = '1', and 0 when it does not.
--
--       This file does NOT complete a container, so the FG LOT is still open here.
--       The guard that CRT never drags in 200% inspection lives in 040 (below),
--       where Container_Complete actually runs and closes the LOT.
--
--       Fixture note: the seeded 6NA ContainerConfig (sql/seeds/020_seed_items.sql)
--       is ByVision only (4 trays x 6 parts), not ByCount -- @ClosureMethod and
--       @PieceCount below match that seeded config. Component stock (12270-6NA-M,
--       92900-06014-1B, 94301-08100) is topped up at the cell before each run with
--       a buffer via Lots.Lot_Create, mirroring sql/scratch/_seed_assembly_stock.sql,
--       since the shared seeded chain carries no stock of its own.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/030_CompleteTray_marks_crt.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

-- ---- teardown (FK-safe order): this file's own FG containers/LOTs only ----
-- Fixture isolation: this shared cell/item's open Container accumulates trays
-- across every run of this file (the orchestrator intentionally never
-- auto-completes a full container -- see Assembly_CompleteTray step 8). A prior
-- run can leave the container at/near its 24-part target, which would reject
-- this file's two 6-part trays with "container is full". Rather than force-close
-- that container mid-schema (which would fabricate a Complete container with no
-- AIM Shipper ID / ShippingLabel -- debris Container_Complete would never
-- produce), delete this file's own FG containers/LOTs outright so a fresh
-- container auto-opens for this run's trays. Scoped to part 12270-6NA -0001 at
-- cell MA1-FP6NA only -- do not touch other fixtures' rows.
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId = @TdCell;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId = @TdCell;
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

-- Fixture: reuse the seeded 6NA assembly chain at MA1-FP6NA.
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');

-- Top up component stock at the cell (BOM: 12270-6NA-M x1, 92900-06014-1B x1,
-- 94301-08100 x2 per FG piece; two trays of 6 need 12/12/24 -- seeded with a
-- buffer so this file can be re-run without stranding the fill).
DECLARE @CompA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @CompB BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @CompC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');
-- Item 12270-6NA-M has MaxLotSize 12, so its top-up is split across two lots.
DECLARE @Stock TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompB, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 30, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompC, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 60, @AppUserId = 1;

-- CRT OFF -> CrtActive 0
DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                    ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
DECLARE @R0 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R0 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;

INSERT INTO @Off EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 6, @CellLocationId = @Cell,
    @ClosureMethod = N'ByVision', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @LotOff BIGINT = (SELECT FinishedGoodLotId FROM @Off);
DECLARE @Act3 NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @LotOff);
EXEC test.Assert_IsEqual @TestName = N'[CrtMint] CRT off -> FG LOT CrtActive = 0',
    @Expected = N'0', @Actual = @Act3;

-- CRT ON -> CrtActive 1
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;

DECLARE @On TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @On EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 6, @CellLocationId = @Cell,
    @ClosureMethod = N'ByVision', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @LotOn BIGINT = (SELECT FinishedGoodLotId FROM @On);
DECLARE @Act4 NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @LotOn);
EXEC test.Assert_IsEqual @TestName = N'[CrtMint] CRT on -> FG LOT CrtActive = 1',
    @Expected = N'1', @Actual = @Act4;

-- reset the terminal so later files start clean
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
GO

-- ---- teardown (FK-safe order): this file's own FG containers/LOTs only ----
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId = @TdCell;
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId = @TdCell;
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

EXEC test.EndTestFile;
