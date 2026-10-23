-- =============================================================================
-- 2026-10-19 -- Dev-only setup: end-to-end test of the office IND570 scale
--               ("MPP Scale" TCP device, 10.20.11.150:1702) on the 6MA oil pan
--               line, MA2-6MAOP. NEVER run against prod.
--
-- What it does (each step idempotent, all through the procs so every change
-- carries validation + audit rows):
--   1. Maps [MPP]PlcDevices/MPP_Scale onto terminal MA2-6MAOP-AOUT (106) as a
--      ScaleStationEPrint device (Location.TerminalPlcDevice_Save).
--   2. Gives FG 1120A-69F -A000 (Item 110) a ByWeight pack-out: 60/tray,
--      1 tray/box, target 50.00 lb +/- 2.00 lb -- matches the "50 lb part"
--      record in the office scale's own Target Table (Malaki's setup), so the
--      MES verdict and the scale's UNDER/OVER/OK flags can be compared
--      (Parts.ContainerConfig_Create).
--   3. Tops up Received stock at the line (104) so every BOM 20 child has
--      @TargetQty available (Lots.Lot_Create, origin Received). The casting's
--      consumption-point Max at 104 is 600, so 600 = 10 good presses.
--   4. Dry run: one Assembly_CompleteTray ByWeight close, ALWAYS rolled back,
--      to prove the DB half of a press succeeds before anyone touches the scale.
--
-- @Commit = 0 runs steps 1-3 inside a transaction and rolls back.
-- Never commit this file armed.
-- =============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Commit    BIT = 0;
DECLARE @AppUserId BIGINT = 22;          -- JGP (Jacques)
DECLARE @TargetQty INT = 600;

DECLARE @Terminal BIGINT = 106, @Cell BIGINT = 104, @Fg BIGINT = 110;
DECLARE @TypeId   BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'ScaleStationEPrint');
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Path     NVARCHAR(400) = N'[MPP]PlcDevices/MPP_Scale';

DECLARE @R TABLE (Status INT, Message NVARCHAR(4000), NewId BIGINT);
DECLARE @RL TABLE (Status INT, Message NVARCHAR(4000), NewId BIGINT, MintedLotName NVARCHAR(50));

BEGIN TRANSACTION;

-- 1. Device mapping ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM Location.TerminalPlcDevice
               WHERE TerminalLocationId = @Terminal AND UdtInstancePath = @Path AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO @R EXEC Location.TerminalPlcDevice_Save
        @TerminalLocationId = @Terminal, @PlcDeviceTypeId = @TypeId,
        @DeviceCode = N'MPP_Scale', @UdtInstancePath = @Path, @AppUserId = @AppUserId;
    SELECT N'1. mapping' AS Step, * FROM @R; DELETE FROM @R;
END
ELSE PRINT '1. mapping already present';

-- 2. ByWeight pack-out -----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig
               WHERE ItemId = @Fg AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO @R EXEC Parts.ContainerConfig_Create
        @ItemId = @Fg, @TraysPerContainer = 1, @PartsPerTray = 60, @IsSerialized = 0,
        @ClosureMethod = N'ByWeight', @TargetWeight = 50.0000, @ToleranceWeight = 2.0000,
        @AppUserId = @AppUserId;
    SELECT N'2. pack-out' AS Step, * FROM @R; DELETE FROM @R;
END
ELSE PRINT '2. ByWeight pack-out already present';

-- 3. Stock top-up ---------------------------------------------------------------
DECLARE @Child BIGINT, @Have INT, @Need INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT bl.ChildItemId FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId = b.Id
    WHERE b.ParentItemId = @Fg AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL;
OPEN c; FETCH NEXT FROM c INTO @Child;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @Have = ISNULL(SUM(l.InventoryAvailable), 0)
    FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId
    WHERE l.ItemId = @Child AND l.CurrentLocationId = @Cell AND s.Code = N'Good';
    SET @Need = @TargetQty - @Have;
    IF @Need > 0
    BEGIN
        INSERT INTO @RL EXEC Lots.Lot_Create
            @ItemId = @Child, @LotOriginTypeId = @Received, @CurrentLocationId = @Cell,
            @PieceCount = @Need, @VendorLotNumber = N'SCALE-TEST-20261019',
            @AppUserId = @AppUserId, @TerminalLocationId = @Terminal;
        SELECT N'3. stock' AS Step, @Child AS ItemId, @Need AS Added, * FROM @RL; DELETE FROM @RL;
    END
    FETCH NEXT FROM c INTO @Child;
END
CLOSE c; DEALLOCATE c;

IF @Commit = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
PRINT CASE WHEN @Commit = 1 THEN 'COMMITTED' ELSE 'ROLLED BACK (preview)' END;

-- 4. Dry-run tray close (always rolled back) -----------------------------------
IF @Commit = 1
BEGIN
    DECLARE @T TABLE (Status INT, Message NVARCHAR(4000), FinishedGoodLotId BIGINT, ContainerId BIGINT,
                      ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
    BEGIN TRANSACTION;
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Fg, @ClosureMethod = N'ByWeight', @Weight = 50.2;
    INSERT INTO @T EXEC Workorder.Assembly_CompleteTray
        @FinishedGoodItemId = @Fg, @PieceCount = 60, @CellLocationId = @Cell,
        @ClosureMethod = N'ByWeight', @AppUserId = 1, @TerminalLocationId = @Terminal;
    ROLLBACK TRANSACTION;
    SELECT N'4. dry-run close (rolled back)' AS Step, * FROM @T;
END
