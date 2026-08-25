-- =============================================
-- File: 0056_CrtValidation/060_Container_ValidateCrt.sql
-- Desc: Container_ValidateCrt - clears the CRT flag on EVERY tray LOT of the
--       container, rejects a container that is not pending (already validated,
--       or unknown). The AIM post itself is the Python caller's step.
--
--       Fixture note: the seeded 6NA ContainerConfig (sql/seeds/020_seed_items.sql)
--       is ByVision only (4 trays x 6 parts = 24-part target), not ByCount/1 -- the
--       brief's original draft fixture used @ClosureMethod = N'ByCount' /
--       @PieceCount = 1 in a single Assembly_CompleteTray call, which does not match
--       the seeded config and would reject at step 4b ("no ByCount pack-out
--       configured"). Corrected here to fill all 4 trays ByVision/6 so the container
--       actually reaches FULL and Container_Complete can run (mirrors
--       030_CompleteTray_marks_crt.sql / 040_ListUnposted_excludes_held.sql /
--       050_Container_ListPendingValidation.sql).
--
--       A container carries ONE finished-good LOT PER TRAY (ContainerTray.
--       FinishedGoodLotId is 1:1 with the tray), so this 4-tray container mints 4
--       CRT-active FG LOTs. Container_ValidateCrt's UPDATE is set-based over all of
--       them, so the strengthened assertion below checks that ZERO tray LOTs remain
--       CrtActive for the container -- the property that actually matters, not just
--       that one LOT's flag cleared.
--
--       Component stock (12270-6NA-M, 92900-06014-1B, 94301-08100) is topped up at
--       the cell before each run, mirroring 030/040/050, since the shared seeded
--       chain carries no stock of its own.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/060_Container_ValidateCrt.sql';
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
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-VAL-1';

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
    SET @t = @t + 1;
END

DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @CompleteStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CC);
EXEC test.Assert_IsEqual @TestName = N'[Validate] Container_Complete succeeds (fixture sanity)',
    @Expected = N'1', @Actual = @CompleteStatus;

-- sanity: all 4 tray LOTs are CrtActive before we validate
DECLARE @PreCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot
    WHERE Id IN (SELECT LotId FROM @TrayLots) AND CrtActive = 1);
EXEC test.Assert_IsEqual @TestName = N'[Validate] fixture sanity: all 4 tray LOTs CrtActive before validation',
    @Expected = N'4', @Actual = @PreCount;

DECLARE @V1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V1 EXEC Lots.Container_ValidateCrt @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Act9 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V1);
EXEC test.Assert_IsEqual @TestName = N'[Validate] returns Status 1',
    @Expected = N'1', @Actual = @Act9;

-- Strengthened beyond the brief: a container carries one FG LOT PER TRAY, not one
-- per container, so a single-LOT check is not the property that matters. Assert
-- that ALL 4 of the container's tray LOTs cleared -- zero remain CrtActive.
DECLARE @Act10 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot
    WHERE Id IN (SELECT LotId FROM @TrayLots) AND CrtActive = 1);
EXEC test.Assert_IsEqual @TestName = N'[Validate] ALL 4 tray LOTs CrtActive cleared to 0 (remaining count)',
    @Expected = N'0', @Actual = @Act10;

-- Finding 1: the per-LOT CRT-clear must reach EACH tray LOT's own genealogy trail
-- (Lots.LotEventLog, 20-yr Honda-traceability retention), not just a single
-- container-level summary row. Assert one 'CrtCleared' row per tray LOT.
DECLARE @Act10b NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Lots.LotEventLog lel
    INNER JOIN Audit.LogEventType let ON let.Id = lel.LogEventTypeId
    WHERE lel.LotId IN (SELECT LotId FROM @TrayLots) AND let.Code = N'CrtCleared');
EXEC test.Assert_IsEqual @TestName = N'[Validate] LotEventLog has one CrtCleared row per tray LOT (4)',
    @Expected = N'4', @Actual = @Act10b;

-- second call must reject: nothing pending any more (Finding 3: this is the
-- @@ROWCOUNT race-guard path taken serially -- assert both the status AND the
-- distinguishing "already validated" message, not just a non-1 status).
DECLARE @V2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V2 EXEC Lots.Container_ValidateCrt @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Act11 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V2);
EXEC test.Assert_IsEqual @TestName = N'[Validate] double-validate rejected, Status 0',
    @Expected = N'0', @Actual = @Act11;
DECLARE @Act11b NVARCHAR(500) = (SELECT Message FROM @V2);
EXEC test.Assert_IsEqual @TestName = N'[Validate] double-validate message is the not-pending rejection',
    @Expected = N'Container is not pending validation.', @Actual = @Act11b;

-- Finding 2: a reject path (container not found) must write an Audit.FailureLog row.
DECLARE @PreFailCount INT = (SELECT COUNT(*) FROM Audit.FailureLog
    WHERE ProcedureName = N'Lots.Container_ValidateCrt' AND EntityId = 999999999);

DECLARE @V3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V3 EXEC Lots.Container_ValidateCrt @ContainerId = 999999999, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Act12 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V3);
EXEC test.Assert_IsEqual @TestName = N'[Validate] unknown container rejected, Status 0',
    @Expected = N'0', @Actual = @Act12;

DECLARE @PostFailCount INT = (SELECT COUNT(*) FROM Audit.FailureLog
    WHERE ProcedureName = N'Lots.Container_ValidateCrt' AND EntityId = 999999999);
DECLARE @FailDelta NVARCHAR(10) = CAST(@PostFailCount - @PreFailCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Validate] unknown-container reject writes an Audit.FailureLog row',
    @Expected = N'1', @Actual = @FailDelta;

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
