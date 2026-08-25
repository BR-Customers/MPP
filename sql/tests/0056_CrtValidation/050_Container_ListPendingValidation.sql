-- =============================================
-- File: 0056_CrtValidation/050_Container_ListPendingValidation.sql
-- Desc: The pending list - line-scoped, drops a container once validated.
--
--       Fixture note: the seeded 6NA ContainerConfig (sql/seeds/020_seed_items.sql)
--       is ByVision only (4 trays x 6 parts = 24-part target), not ByCount/1 -- the
--       brief's original draft fixture used @ClosureMethod = N'ByCount' /
--       @PieceCount = 1 in a single Assembly_CompleteTray call, which does not match
--       the seeded config and would reject at step 4b ("no ByCount pack-out
--       configured"). Corrected here to fill all 4 trays ByVision/6 so the container
--       actually reaches FULL and Container_Complete can run (mirrors
--       030_CompleteTray_marks_crt.sql and 040_ListUnposted_excludes_held.sql).
--
--       A container carries ONE finished-good LOT PER TRAY (ContainerTray.
--       FinishedGoodLotId is 1:1 with the tray), so this 4-tray container mints 4
--       CRT-active FG LOTs. The proc's join is per-tray-LOT, so "validated -> drops
--       out" requires clearing CRT on ALL 4 tray LOTs, not just one -- mirrors 040's
--       clr_cur loop. Along the way this also exercises PendingLotCount = 4 while
--       all four are still CrtActive, the concrete case the brief's header calls out.
--
--       Component stock (12270-6NA-M, 92900-06014-1B, 94301-08100) is topped up at
--       the cell before each run, mirroring 030/040, since the shared seeded chain
--       carries no stock of its own.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/050_Container_ListPendingValidation.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

-- ---- teardown (FK-safe order): this file's own FG containers/LOTs only ----
-- Scoped to part 12270-6NA -0001 at cell MA1-FP6NA only -- do not touch other fixtures' rows.
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

DECLARE @Cell  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-LIST-1';

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
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
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

    -- Finding 1 regression: after just ONE tray closes, the container is still OPEN
    -- (CompletedAt IS NULL) -- but that tray's FG LOT is already CrtActive (minted at
    -- TRAY close). Before the fix this mid-fill container leaked into the pending list
    -- with a NULL AimShipperId. Must NOT be listed until the container itself completes.
    IF @t = 1
    BEGIN
        DECLARE @LMidFill TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
            PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
        INSERT INTO @LMidFill EXEC Lots.Container_ListPendingValidation @LocationId = @Cell, @ContainerId = NULL;
        DECLARE @ActMidFill NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @LMidFill WHERE ContainerId = @Con);
        EXEC test.Assert_IsEqual @TestName = N'[Pending] mid-fill container (1 of 4 trays closed) is NOT listed',
            @Expected = N'0', @Actual = @ActMidFill;
    END

    SET @t = @t + 1;
END
-- ... and once the remaining trays close and the container itself completes, it now appears
-- (proven below by the existing "[Pending] held container is listed for its line" assert).

DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @CompleteStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CC);
EXEC test.Assert_IsEqual @TestName = N'[Pending] Container_Complete succeeds (fixture sanity)',
    @Expected = N'1', @Actual = @CompleteStatus;

DECLARE @L1 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @L1 EXEC Lots.Container_ListPendingValidation @LocationId = @Cell, @ContainerId = NULL;
DECLARE @Act5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L1 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] held container is listed for its line',
    @Expected = N'1', @Actual = @Act5;

-- one row per container, not one row per pending tray-LOT -- PendingLotCount carries the count
DECLARE @Act5b NVARCHAR(10) = (SELECT CAST(PendingLotCount AS NVARCHAR(10)) FROM @L1 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] PendingLotCount reflects all 4 tray LOTs',
    @Expected = N'4', @Actual = @Act5b;

DECLARE @L2 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @L2 EXEC Lots.Container_ListPendingValidation @LocationId = @Other, @ContainerId = NULL;
DECLARE @Act6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L2 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] a different line does NOT see it',
    @Expected = N'0', @Actual = @Act6;

-- @ContainerId probe (the path Container.complete / _isCrtHeld uses)
DECLARE @L3 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @L3 EXEC Lots.Container_ListPendingValidation @LocationId = NULL, @ContainerId = @Con;
DECLARE @Act7 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L3);
EXEC test.Assert_IsEqual @TestName = N'[Pending] container probe finds the held container',
    @Expected = N'1', @Actual = @Act7;

-- validated -> drops out. Clear ALL 4 tray LOTs -- the proc's join is per-tray-LOT (any
-- CrtActive LOT keeps the container in the list), mirroring 040's clr_cur loop.
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

DECLARE @L4 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @L4 EXEC Lots.Container_ListPendingValidation @LocationId = @Cell, @ContainerId = NULL;
DECLARE @Act8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L4 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] validated container drops out of the list',
    @Expected = N'0', @Actual = @Act8;

DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Off EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DELETE FROM Lots.AimShipperIdPool;
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
