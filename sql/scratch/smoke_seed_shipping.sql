-- ============================================================
-- smoke_seed_shipping.sql
-- Test path for the SHIPPING DOCK + RECEIVING screens (smoke finding
-- 2026-07-09): stages, via the PRODUCTION procs (no hand-faked rows):
--   1) a COMPLETE but UNSHIPPED 6MA container at MA1-FPRPY-AFIN --
--      AIM Shipper ID claimed + ShippingLabel minted (PrintedAt NULL),
--      ready for the Shipping Dock's Ship action (FDS-07-005 path:
--      Assembly_CompleteTray x2 -> full -> Container_Complete).
--   2) a fresh RD-BRKT received LOT on the dock (SHIPIN) for the
--      Receiving screen's list (the screen itself can mint more).
--
-- Prereqs: sql/seeds config (020/029) + demo topology; run any time after
-- Reset-DevDatabase / seed_demo. RE-RUNNABLE: each run stages a NEW
-- container + dock LOT (consumes one AIM pool id per run; a drained pool
-- fails loudly and the container correctly stays OPEN, FDS-07-010a).
--
-- Usage: sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/smoke_seed_shipping.sql
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
USE MPP_MES_Dev;

DECLARE @ErrMsg NVARCHAR(500);
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
IF @U IS NULL SET @U = 1;

DECLARE @I_6MA    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA');
DECLARE @I_6MAM   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-M');
DECLARE @I_PINA   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PIN-A');
DECLARE @I_RDBRKT BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RD-BRKT');
-- Resolve locations from ELIGIBILITY, not hardcoded codes: the 6MA family's home
-- differs between the pristine seeds (MA1-FPRPY-AFIN) and interactive dev config
-- (e.g. MA2-6MACH). @L_ASSY = where the 6MA FG is directly eligible (the assembly
-- point); @L_MSTAGE = where 6MA-M is directly eligible (staging point; moved over
-- with the unvalidated Lot_MoveTo when different).
DECLARE @L_ASSY BIGINT = (SELECT TOP 1 LocationId FROM Parts.v_EffectiveItemLocation
                          WHERE ItemId = @I_6MA AND Source = N'Direct' ORDER BY LocationId);
DECLARE @L_MSTAGE BIGINT = (SELECT TOP 1 LocationId FROM Parts.v_EffectiveItemLocation
                            WHERE ItemId = @I_6MAM AND Source = N'Direct' ORDER BY LocationId);
DECLARE @AssyCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @L_ASSY);
DECLARE @L_SHIPIN BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPIN');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

IF @I_6MA IS NULL OR @L_ASSY IS NULL OR @L_MSTAGE IS NULL
BEGIN
    PRINT 'Demo config (6MA eligibility / 6MA-M eligibility) not found - run the sql/seeds config first.';
    RETURN;
END
PRINT N'Assembly point resolved: ' + ISNULL(@AssyCode, N'?');

DECLARE @PoolFree INT = (SELECT COUNT(*) FROM Lots.AimShipperIdPool
                         WHERE ConsumedAt IS NULL AND PartNumber = N'6MA');
PRINT N'AIM pool free ids for 6MA: ' + CAST(@PoolFree AS NVARCHAR(10));
IF @PoolFree = 0
BEGIN
    PRINT 'AIM pool for 6MA is drained - Container_Complete would (correctly) hard-fail (FDS-07-010a). Reseed the pool first.';
    RETURN;
END

DECLARE @rLot  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rTray TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
DECLARE @rComp TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));

-- ---- 1. stage assembly inputs at the resolved assembly point (6MA-M created
--         where it is directly eligible, then moved over with the unvalidated
--         Lot_MoveTo; interim direct-stage pending the keep-identity assembly
--         follow-up -- normally Machining OUT mints it) ----
DECLARE @rMove TABLE (Status BIT, Message NVARCHAR(500));
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAM, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_MSTAGE, @PieceCount = 24, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-M stage Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @MLot BIGINT = (SELECT NewId FROM @rLot);
IF @L_MSTAGE <> @L_ASSY
BEGIN
    INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @MLot, @ToLocationId = @L_ASSY, @AppUserId = @U;
    IF (SELECT Status FROM @rMove) <> 1
    BEGIN SET @ErrMsg = N'6MA-M move to assembly point failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
END

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_PINA, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_ASSY, @PieceCount = 48, @VendorLotNumber = N'PINA-VEND-SHIPSEED', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'PIN-A stage Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

-- ---- 2. two trays -> container full (Assembly_CompleteTray auto-opens) ----
DELETE FROM @rTray;
INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_6MA, @PieceCount = 12, @CellLocationId = @L_ASSY, @AppUserId = @U;
IF (SELECT Status FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'Tray 1 failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @Container BIGINT = (SELECT ContainerId FROM @rTray);

DELETE FROM @rTray;
INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_6MA, @PieceCount = 12, @CellLocationId = @L_ASSY, @AppUserId = @U;
IF (SELECT Status FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'Tray 2 failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
IF (SELECT ContainerFull FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'Container did not report full after 2 trays.'; THROW 51000, @ErrMsg, 1; END

-- ---- 3. COMPLETE the container (claims AIM id + mints the label) - DO NOT ship ----
DELETE FROM @rComp;
INSERT INTO @rComp EXEC Lots.Container_Complete @ContainerId = @Container, @OperatorConfirmed = 1, @AppUserId = @U;
IF (SELECT Status FROM @rComp) <> 1
BEGIN SET @ErrMsg = N'Container_Complete failed: ' + ISNULL((SELECT Message FROM @rComp), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @Label BIGINT = (SELECT ShippingLabelId FROM @rComp);
DECLARE @Aim NVARCHAR(50) = (SELECT AimShipperId FROM @rComp);

-- ---- 4. a fresh received LOT on the dock for the Receiving screen ----
DECLARE @DockName NVARCHAR(50) = NULL;
IF @I_RDBRKT IS NOT NULL AND @L_SHIPIN IS NOT NULL
BEGIN
    DELETE FROM @rLot;
    INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_RDBRKT, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_SHIPIN, @PieceCount = 100, @VendorLotNumber = N'RDBRKT-VEND-SHIPSEED', @AppUserId = @U;
    IF (SELECT Status FROM @rLot) <> 1
    BEGIN SET @ErrMsg = N'RD-BRKT dock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
    SET @DockName = (SELECT MintedLotName FROM @rLot);
END

PRINT N'';
PRINT N'==================================================================';
PRINT N'  SHIPPING / RECEIVING SMOKE READY';
PRINT N'==================================================================';
PRINT N'1) SHIPPING DOCK  /shop-floor/shipping';
PRINT N'     Container ' + CAST(@Container AS NVARCHAR(20)) + N' is COMPLETE + UNSHIPPED at ' + ISNULL(@AssyCode, N'?') + N'.';
PRINT N'     AIM ' + ISNULL(@Aim, N'?') + N', ShippingLabel Id ' + CAST(@Label AS NVARCHAR(20)) + N' (PrintedAt NULL - reprint testable).';
PRINT N'     Ship it from the dock and confirm the status flip + audit row.';
PRINT N'2) RECEIVING  /shop-floor/receiving';
IF @DockName IS NOT NULL
    PRINT N'     LOT ' + @DockName + N' (RD-BRKT, 100 pcs) is on the dock at SHIPIN; receive more via the screen itself.';
ELSE
    PRINT N'     (RD-BRKT/SHIPIN not configured - use the screen to mint receipts.)';
PRINT N'==================================================================';
GO
