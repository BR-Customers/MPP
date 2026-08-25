-- =============================================
-- File: 0056_CrtValidation/040_ListUnposted_excludes_held.sql
-- Desc: THE regression guard. AimShipperIdPool_ListUnposted is the single query
--       behind AimPost.retryTick, the owed-to-AIM backlog screen and alarmTick's
--       age escalation. A CRT-held container's serial must not appear there, or
--       the 60s sweep posts it and the whole feature is silently defeated.
--
--       Pool convention: blanket-DELETE on entry and top up our own IDs - the
--       seeded pool is destroyed by earlier pool-touching files in a full run.
--
--       Fixture note: the seeded 6NA ContainerConfig (sql/seeds/020_seed_items.sql)
--       is ByVision only (4 trays x 6 parts = 24-part target), not ByCount/1 --
--       the brief's original draft fixture used @ClosureMethod = N'ByCount' /
--       @PieceCount = 1, which does not match the seeded config and would reject
--       at Assembly_CompleteTray step 4b ("no ByCount pack-out configured").
--       Corrected here to fill all 4 trays ByVision/6 so the container actually
--       reaches FULL and Container_Complete can run (mirrors 030's fixture setup
--       and 0028/040's fill-every-tray loop). Component stock (12270-6NA-M,
--       92900-06014-1B, 94301-08100) is topped up at the cell before each run,
--       mirroring 030_CompleteTray_marks_crt.sql, since the shared seeded chain
--       carries no stock of its own.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/040_ListUnposted_excludes_held.sql';
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

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-1';

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
-- tray = LOT (Assembly_CompleteTray mints one FG LOT per tray), so a 4-tray container
-- carries 4 CRT-active FG LOTs. ListUnposted's NOT EXISTS is per-container (any tray's
-- LOT still CrtActive holds the whole serial), so freeing the serial for the sweep
-- requires clearing CRT on ALL of the container's tray LOTs, not just the last one.
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
EXEC test.Assert_IsEqual @TestName = N'[Held] Container_Complete succeeds (fixture sanity)',
    @Expected = N'1', @Actual = @CompleteStatus;

-- the serial IS consumed (that part of the behaviour is unchanged)
DECLARE @Claimed NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Lots.AimShipperIdPool WHERE ConsumedByContainerId = @Con) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Held] serial is still CLAIMED at completion',
    @Expected = N'1', @Actual = @Claimed;

-- ...but must NOT be offered to the sweep
DECLARE @U1 TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(50),
    Quantity INT, LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(500),
    ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @U1 EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @Held NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @U1 WHERE ContainerId = @Con) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Held] CRT-held serial is EXCLUDED from ListUnposted',
    @Expected = N'0', @Actual = @Held;

-- THE 200%-INSPECTION GUARD. Reusing Lots.Lot.CrtActive is only safe because
-- Container_Complete closes the FG LOT and Quality.Crt_GetRequiredInspections filters
-- sc.Code <> 'Closed'. If the FG LOT ever stops closing at completion, every CRT
-- container would silently start demanding 200% inspection. Assert both halves.
DECLARE @Act9 NVARCHAR(10) = (SELECT sc.Code FROM Lots.Lot l
    JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Held] FG LOT is Closed after container completion',
    @Expected = N'Closed', @Actual = @Act9;

DECLARE @Insp TABLE (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50),
    PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO @Insp EXEC Quality.Crt_GetRequiredInspections @LocationId = @Cell;
DECLARE @Act10 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Insp WHERE LotId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Held] CRT-active but Closed -> NOT in the 200% inspection surface',
    @Expected = N'0', @Actual = @Act10;

-- clearing CRT hands it straight back to the normal retry machinery. Clear ALL
-- 4 tray LOTs -- ListUnposted's NOT EXISTS only releases the container once none
-- of its trays carry a CrtActive LOT.
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

DECLARE @U2 TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(50),
    Quantity INT, LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(500),
    ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @U2 EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @Freed NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @U2 WHERE ContainerId = @Con) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Held] cleared CRT -> serial reappears for the sweep',
    @Expected = N'1', @Actual = @Freed;

DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Off EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
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
