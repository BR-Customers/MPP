-- =============================================
-- File: 0056_CrtValidation/070_Ship_blocked_when_pending.sql
-- Desc: Whole-feature review Finding 1 (BLOCKING). Lots.Container_Ship must reject a
--       container that is still pending Controlled Run Tag validation (any tray's FG
--       LOT CrtActive = 1) -- shipping it first would send Honda unvalidated product
--       AND strand the AIM serial forever (the ship moves CurrentLocationId, which
--       drops the container out of Container_ListPendingValidation's location scope
--       while AimShipperIdPool_ListUnposted still excludes it). Once every tray LOT
--       is validated (CRT cleared), the SAME container ships normally.
--
--       Fixture note: mirrors 050_Container_ListPendingValidation.sql -- the seeded
--       6NA ContainerConfig (sql/seeds/020_seed_items.sql) is ByVision only (4 trays
--       x 6 parts = 24-part target), so all 4 trays are closed via
--       Workorder.Assembly_CompleteTray with the terminal's CrtEnabled = 1, then
--       Container_Complete claims the AIM serial and mints the ShippingLabel that
--       Lots.Container_Ship takes (@ShippingLabelId, not a container id).
--
--       Component stock (12270-6NA-M, 92900-06014-1B, 94301-08100) is topped up at
--       the cell before each run, mirroring 030/040/050, since the shared seeded
--       chain carries no stock of its own.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/070_Ship_blocked_when_pending.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

-- ---- teardown (FK-safe order): this file's own FG containers/LOTs only ----
-- Scoped to part 12270-6NA -0001 at cell MA1-FP6NA only -- do not touch other fixtures' rows.
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
-- A successfully-shipped container moves CurrentLocationId -> SHIPOUT (that's the whole
-- point of this file's second half), so container-scoped teardown below must also catch
-- SHIPOUT or a validated-and-shipped container from a prior run leaks forever. LOTs never
-- move (Container_Ship only touches the container row), so LOT-scoped deletes stay @TdCell-only.
DECLARE @TdShip BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPOUT');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip));
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-SHIP-1';

-- Top up component stock at the cell (BOM: 12270-6NA-M x1, 92900-06014-1B x1,
-- 94301-08100 x2 per FG piece; 4 trays of 6 = 24 pieces needs 24/24/48, seeded
-- with a buffer so this file can be re-run without stranding the fill).
-- Item 12270-6NA-M has MaxLotSize 12, so its top-up is split across three lots.
DECLARE @CompA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @CompB BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @CompC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');
DECLARE @Stock TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompB, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 60, @AppUserId = 1;
INSERT INTO @Stock EXEC Lots.Lot_Create @ItemId = @CompC, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 120, @AppUserId = 1;

DECLARE @On TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @On EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;

-- close all 4 trays (ByVision, 6 parts each = 24-part target) so the container reaches FULL
DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
DECLARE @t INT = 1;
DECLARE @Con BIGINT;
DECLARE @Lot BIGINT;
DECLARE @TrayLots TABLE (LotId BIGINT);
WHILE @t <= 4
BEGIN
    DELETE FROM @AT;
    INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray
        @FinishedGoodItemId = @Fg, @PieceCount = 6, @CellLocationId = @Cell,
        @ClosureMethod = N'ByVision', @AppUserId = 1, @TerminalLocationId = @Term;
    SET @Con = (SELECT ContainerId FROM @AT);
    SET @Lot = (SELECT FinishedGoodLotId FROM @AT);
    INSERT INTO @TrayLots (LotId) VALUES (@Lot);
    SET @t = @t + 1;
END

DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @CompleteStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CC);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] Container_Complete succeeds (fixture sanity)',
    @Expected = N'1', @Actual = @CompleteStatus;
DECLARE @Slid BIGINT = (SELECT ShippingLabelId FROM @CC);

-- ---- THE FIX: ship must reject while any tray LOT is still CRT-pending ----
DECLARE @SH1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @SH1 EXEC Lots.Container_Ship @ShippingLabelId = @Slid, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH1);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] ship rejects while CRT-pending (Status 0)',
    @Expected = N'0', @Actual = @S1;

DECLARE @Msg1 NVARCHAR(500) = (SELECT Message FROM @SH1);
DECLARE @MsgHasCrt NVARCHAR(10) = CASE WHEN @Msg1 LIKE N'%Controlled Run Tag%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] rejection message names Controlled Run Tag',
    @Expected = N'1', @Actual = @MsgHasCrt;

-- container must NOT have moved -- still at the cell, still Complete (not Shipped)
DECLARE @StAfterBlock NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] blocked container stays Complete (2), not Shipped',
    @Expected = N'2', @Actual = @StAfterBlock;
DECLARE @LocAfterBlock NVARCHAR(10) = (SELECT CASE WHEN CurrentLocationId = @Cell THEN N'1' ELSE N'0' END FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] blocked container has NOT moved off the cell',
    @Expected = N'1', @Actual = @LocAfterBlock;

-- it must also still be visible on the pending-validation list -- the whole point of the fix
DECLARE @LP TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @LP EXEC Lots.Container_ListPendingValidation @LocationId = @Cell, @ContainerId = NULL;
DECLARE @StillPending NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @LP WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] blocked container is still on the pending-validation list',
    @Expected = N'1', @Actual = @StillPending;

-- ---- validate all 4 tray LOTs (mirrors 040/050's clr_cur loop), then the SAME container ships ----
DECLARE @ClrLot BIGINT;
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500));
DECLARE clr_cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId FROM @TrayLots;
OPEN clr_cur;
FETCH NEXT FROM clr_cur INTO @ClrLot;
WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM @CL;
    INSERT INTO @CL EXEC Lots.Lot_ClearCrt @LotId = @ClrLot, @AppUserId = 1, @TerminalLocationId = @Term;
    FETCH NEXT FROM clr_cur INTO @ClrLot;
END
CLOSE clr_cur; DEALLOCATE clr_cur;

DECLARE @SH2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @SH2 EXEC Lots.Container_Ship @ShippingLabelId = @Slid, @AppUserId = 2, @TerminalLocationId = @Term;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @SH2);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] once validated, the SAME container ships (Status 1)',
    @Expected = N'1', @Actual = @S2;

DECLARE @StAfterShip NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[ShipBlock] validated container -> Shipped (3)',
    @Expected = N'3', @Actual = @StAfterShip;

DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Off EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DELETE FROM Lots.AimShipperIdPool;
GO

-- ---- teardown (FK-safe order): this file's own FG containers/LOTs only ----
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
-- A successfully-shipped container moves CurrentLocationId -> SHIPOUT (that's the whole
-- point of this file's second half), so container-scoped teardown below must also catch
-- SHIPOUT or a validated-and-shipped container from a prior run leaks forever. LOTs never
-- move (Container_Ship only touches the container row), so LOT-scoped deletes stay @TdCell-only.
DECLARE @TdShip BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPOUT');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip));
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId IN (@TdCell, @TdShip);
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

EXEC test.EndTestFile;
