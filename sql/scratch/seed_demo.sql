-- ============================================================
-- seed_demo.sql
-- Continuous Demo Seed Dataset. Idempotent transactional wipe + rebuild of
-- connected demo threads on the current Honda part set (5G0 / 6NA), via the
-- production stored procs, on top of the clean config loaded by sql/seeds
-- (020_seed_items.sql + 029_seed_item_routes.sql).
--
-- NOT a migration, NOT a test. Re-runnable: the wipe deletes ALL transactional
-- Lots/Workorder/Oee/Quality data (FK-safe order), then rebuilds identical thread
-- SHAPES via the real mutation procs, so genealogy/closure/consumption/audit are
-- authentic. Config (Parts.*, Location.*, code tables) is left intact; only the
-- die-cast ToolAssignment MOUNTs this script creates are additive/idempotent.
--
-- NO hardcoded `USE`: this runs against whatever database sqlcmd is connected to
-- (Reset-DevDatabase.ps1 invokes it with -d <DatabaseName>). Run with -I (the
-- Lots.* tables carry filtered indexes -> Msg 1934 without QUOTED_IDENTIFIER ON).
--
-- Threads built (terminal-mint model):
--   6NA-SHIP : 2x [12270-6NA cast -> trim -> mach-in -> mach-out mint 12270-6NA-M]
--              -> 24 machined -> 4 trays of 6 -> container COMPLETE + SHIPPED.
--   6NA-WIP  : WIP LOT staged at every 6NA terminal (die-cast / trim / mach-in
--              unworked / mach-out) + a machined LOT + fasteners left at the
--              assembly cell for a fresh container. The mach-out LOT carries the
--              pause + reject exercisers.
--   5G0-SER  : 5G0-c cast -> trim -> mach-in -> mach-out mint 5G0-SA -> serialized
--              placement (4 serials in an open 5G0-FG container) + a Quality hold.
--   RECEIVE  : a Received 21001 pin LOT (purchased part) at MA1 (where eligible).
--   Cross-cut: downtime open at the 6NA line.
--
-- All locations/parts/users resolved BY CODE / natural key, never a hardcoded Id.
-- ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================
-- STEP 1: Idempotent transactional wipe (FK-safe order). Release AIM pool claims
-- BEFORE deleting Containers (FK_AimPool_Container).
-- ============================================================
DELETE FROM Workorder.ConsumptionEvent;
DELETE FROM Workorder.ProductionEventValue;
DELETE FROM Workorder.ProductionEvent;
DELETE FROM Workorder.RejectEvent;
DELETE FROM Oee.DowntimeEvent;
DELETE FROM Quality.HoldEvent;
DELETE FROM Lots.PauseEvent;

UPDATE Lots.AimShipperIdPool
SET ConsumedAt = NULL, ConsumedByContainerId = NULL, ConsumedByUserId = NULL
WHERE ConsumedByContainerId IS NOT NULL;

DELETE FROM Lots.ShippingLabel;
DELETE FROM Lots.ContainerSerialHistory;
DELETE FROM Lots.ContainerSerial;
DELETE FROM Lots.ContainerTray;
DELETE FROM Lots.Container;
DELETE FROM Lots.SerializedPart;
DELETE FROM Lots.LotLabel;
DELETE FROM Lots.LotAttributeChange;
DELETE FROM Lots.LotMovement;
DELETE FROM Lots.LotStatusHistory;
DELETE FROM Lots.LotGenealogy;
DELETE FROM Lots.LotGenealogyClosure;
DELETE FROM Lots.LotEventLog;
DELETE FROM Workorder.WorkOrderOperation;
DELETE FROM Workorder.WorkOrder;
DELETE FROM Lots.Lot;
GO
PRINT N'Step 1: transactional wipe complete.';
GO

-- ============================================================
-- STEP 2: Die-cast tool mounts (idempotent -- guarded by Code / CellLocationId).
--   DEMO-DC-6NA @ DC3-M01   (12270-6NA fuel-pump casting)
--   DEMO-DC-5G0 @ DC1-M01   (5G0 front-cover casting)
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @L_DC3M01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC3-M01');
DECLARE @L_DC1M01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @ToolTypeDie      BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @CavActive        BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

-- ---- DEMO-DC-6NA @ DC3-M01 ----
DECLARE @ToolId6NA BIGINT;
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'DEMO-DC-6NA')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolTypeDie, N'DEMO-DC-6NA', N'Demo Die - 6NA Fuel Pump Base', @ToolStatusActive, @U, SYSUTCDATETIME());
SET @ToolId6NA = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-6NA');
IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @ToolId6NA)
    INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolId6NA, 1, @CavActive, @U, SYSUTCDATETIME()), (@ToolId6NA, 2, @CavActive, @U, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolId6NA AND CellLocationId = @L_DC3M01 AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@ToolId6NA, @L_DC3M01, SYSUTCDATETIME(), @U);

-- ---- DEMO-DC-5G0 @ DC1-M01 ----
DECLARE @ToolId5G0 BIGINT;
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'DEMO-DC-5G0')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolTypeDie, N'DEMO-DC-5G0', N'Demo Die - 5G0 Front Cover', @ToolStatusActive, @U, SYSUTCDATETIME());
SET @ToolId5G0 = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-5G0');
IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @ToolId5G0)
    INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolId5G0, 1, @CavActive, @U, SYSUTCDATETIME()), (@ToolId5G0, 2, @CavActive, @U, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolId5G0 AND CellLocationId = @L_DC1M01 AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@ToolId5G0, @L_DC1M01, SYSUTCDATETIME(), @U);

PRINT N'Step 2: die-cast tool mounts ready (DEMO-DC-6NA @ DC3-M01, DEMO-DC-5G0 @ DC1-M01).';
GO

-- ============================================================
-- STEP 3: Build the threads. One contiguous batch (table variables persist).
-- Fail-fast: after each capture, THROW on Status <> 1 (this is a standalone
-- scratch script, not a stored proc -- THROW aborts the batch, which is what a
-- fail-fast orchestrator needs; the "RAISERROR not THROW" rule governs proc
-- CATCH blocks, FDS-11-011).
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @ErrMsg NVARCHAR(1000);

-- ---- Locations (by Code) ----
DECLARE @L_DC3M01     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC3-M01');
DECLARE @L_DC1M01     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @L_TRIM1      BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @L_6NA        BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @L_6NA_MIN    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN');
DECLARE @L_6NA_MOUT   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @L_6NA_AFIN   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN');
DECLARE @L_5GOF       BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @L_5GOF_MIN   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @L_5GOF_MOUT  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @L_5GOF_ASER  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-ASER');
DECLARE @L_SHIPIN     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPIN');
DECLARE @L_MA1        BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');

-- ---- Items (by PartNumber) ----
DECLARE @I_6NAcast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @I_6NAmach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @I_6NAfg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @I_stud    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @I_dowel   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');
DECLARE @I_5G0cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @I_5G0mach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
DECLARE @I_5G0fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-FG');
DECLARE @I_pin     BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'21001 pin');

-- ---- Tools (mounted in Step 2) ----
DECLARE @ToolId6NA BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-6NA');
DECLARE @CavId6NA  BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId6NA ORDER BY CavityNumber);
DECLARE @ToolId5G0 BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-5G0');
DECLARE @CavId5G0  BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId5G0 ORDER BY CavityNumber);

-- ---- Code-table lookups ----
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OT_TrimOut      BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut' AND DeprecatedAt IS NULL);
DECLARE @OT_MachiningOut BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut' AND DeprecatedAt IS NULL);
DECLARE @CC_6NAfg BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @I_6NAfg AND DeprecatedAt IS NULL);
DECLARE @CC_5G0fg BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @I_5G0fg AND DeprecatedAt IS NULL);
DECLARE @HoldQuality BIGINT = (SELECT Id FROM Quality.HoldTypeCode WHERE Code = N'Quality');
DECLARE @DefectId    BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode ORDER BY Id);
DECLARE @DtSrc       BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

-- ---- Result-capture table variables ----
DECLARE @rLot   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rMove  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @rTrim  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMin   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMint  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rTray  TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
DECLARE @rComp  TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @rShip  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @rPause TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rHold  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rRej   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rDown  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rSer   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
DECLARE @rCsAdd TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rConOp TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- scratch scalars reused across the cast->machine sequences
DECLARE @cast BIGINT, @mach BIGINT;

-- ============================================================
-- Stage purchased fasteners at the 6NA assembly cell (consumed by Assembly_CompleteTray).
-- ============================================================
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_stud, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_6NA_AFIN, @PieceCount = 40, @VendorLotNumber = N'STUD-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'stud stock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_dowel, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_6NA_AFIN, @PieceCount = 80, @VendorLotNumber = N'DOWEL-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'dowel stock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

-- ============================================================
-- 6NA-SHIP: two cast->machine cycles (24 machined) -> 4 trays -> ship.
-- ============================================================
PRINT N'--- 6NA-SHIP: cast x2 -> machine -> assemble 4 trays -> ship ---';

-- cycle 1
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c1 cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c1 move-trim failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @ScrapCount = 0, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c1 trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c1 mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c1 mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
SET @mach = (SELECT NewId FROM @rMint);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @mach, @ToLocationId = @L_6NA_AFIN, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c1 move-afin failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- cycle 2
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000002', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c2 cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c2 move-trim failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @ScrapCount = 0, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c2 trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c2 mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c2 mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
SET @mach = (SELECT NewId FROM @rMint);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @mach, @ToLocationId = @L_6NA_AFIN, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP c2 move-afin failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- 4 trays of 6 -> container fills (4 x 6 = 24).
DECLARE @ShipContainer BIGINT, @tray INT = 1;
WHILE @tray <= 4
BEGIN
    DELETE FROM @rTray;
    INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_6NAfg, @PieceCount = 6, @CellLocationId = @L_6NA_AFIN, @ClosureMethod = N'ByVision', @AppUserId = @U;
    IF (SELECT Status FROM @rTray) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP tray ' + CAST(@tray AS NVARCHAR(2)) + N' failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
    SET @ShipContainer = (SELECT ContainerId FROM @rTray);
    SET @tray = @tray + 1;
END

DELETE FROM @rComp;
INSERT INTO @rComp EXEC Lots.Container_Complete @ContainerId = @ShipContainer, @OperatorConfirmed = 1, @AppUserId = @U;
IF (SELECT Status FROM @rComp) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP Container_Complete failed: ' + ISNULL((SELECT Message FROM @rComp), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @ShipLabel BIGINT = (SELECT ShippingLabelId FROM @rComp);
DECLARE @ShipAim NVARCHAR(50) = (SELECT AimShipperId FROM @rComp);

DELETE FROM @rShip;
INSERT INTO @rShip EXEC Lots.Container_Ship @ShippingLabelId = @ShipLabel, @AppUserId = @U;
IF (SELECT Status FROM @rShip) <> 1 BEGIN SET @ErrMsg = N'6NA-SHIP Container_Ship failed: ' + ISNULL((SELECT Message FROM @rShip), N'?'); THROW 51000, @ErrMsg, 1; END
PRINT N'    6NA-SHIP complete: container ' + CAST(@ShipContainer AS NVARCHAR(20)) + N' shipped, AIM ' + ISNULL(@ShipAim, N'?') + N'.';

-- ============================================================
-- 6NA-WIP: a LOT at every 6NA terminal + a machined LOT left at assembly.
-- ============================================================
PRINT N'--- 6NA-WIP: WIP staged at every terminal ---';

-- die-cast WIP (untouched cast at DC3-M01)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000003', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP die-cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @W_DieCast NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

-- trim WIP (cast moved to TRIM1, not trimmed out)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000004', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP trim cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DECLARE @W_Trim NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP trim move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- machining-IN unworked WIP (cast trimmed to MA1-FP6NA-MIN, not picked)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000005', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MIN cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DECLARE @W_MinCast NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MIN move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @ScrapCount = 0, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MIN trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END

-- machining-OUT WIP (a fresh machined LOT parked at MOUT) -- carries pause + reject
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000006', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MOUT cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MOUT move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @ScrapCount = 0, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MOUT trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MOUT mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP MOUT mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @W_MoutMach BIGINT = (SELECT NewId FROM @rMint);
DECLARE @W_MoutMachName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @W_MoutMach);

-- assembly-ready: one more machined LOT left AT the assembly cell (Noah opens a container)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6NAcast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId6NA, @ToolCavityId = @CavId6NA, @LotName = N'800000007', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP AFIN cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP AFIN move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @ScrapCount = 0, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP AFIN trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP AFIN mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP AFIN mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
SET @mach = (SELECT NewId FROM @rMint);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @mach, @ToLocationId = @L_6NA_AFIN, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'6NA-WIP AFIN move-afin failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

PRINT N'    6NA-WIP ready: die-cast=' + @W_DieCast + N', trim=' + @W_Trim + N', mach-in unworked=' + @W_MinCast + N', mach-out=' + @W_MoutMachName + N'.';

-- ============================================================
-- 5G0-SER: serialized front cover -> 4 serials in an open container + a hold.
-- ============================================================
PRINT N'--- 5G0-SER: cast -> machine -> serialized placement + hold ---';

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_5G0cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId5G0, @ToolCavityId = @CavId5G0, @LotName = N'800000008', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'5G0 cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'5G0 move-trim failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 24, @ScrapCount = 0, @DestinationCellLocationId = @L_5GOF_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'5G0 trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_5GOF, @AppUserId = @U, @TerminalLocationId = @L_5GOF_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'5G0 mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 24, @AppUserId = @U, @TerminalLocationId = @L_5GOF_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'5G0 mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_Mach BIGINT = (SELECT NewId FROM @rMint);
DECLARE @G_MachName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @G_Mach);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @G_Mach, @ToLocationId = @L_5GOF_ASER, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'5G0 move-aser failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- open a serialized container + place 4 serials from the producing machined LOT
DELETE FROM @rConOp;
INSERT INTO @rConOp EXEC Lots.Container_Open @ItemId = @I_5G0fg, @ContainerConfigId = @CC_5G0fg, @CellLocationId = @L_5GOF_ASER, @AppUserId = @U;
IF (SELECT Status FROM @rConOp) <> 1 BEGIN SET @ErrMsg = N'5G0 Container_Open failed: ' + ISNULL((SELECT Message FROM @rConOp), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_Container BIGINT = (SELECT NewId FROM @rConOp);

DECLARE @G_i INT = 1, @G_SerialId BIGINT;
WHILE @G_i <= 4
BEGIN
    DELETE FROM @rSer;
    INSERT INTO @rSer EXEC Lots.SerializedPart_Mint @ItemId = @I_5G0fg, @ProducingLotId = @G_Mach, @AppUserId = @U;
    IF (SELECT Status FROM @rSer) <> 1 BEGIN SET @ErrMsg = N'5G0 SerializedPart_Mint failed: ' + ISNULL((SELECT Message FROM @rSer), N'?'); THROW 51000, @ErrMsg, 1; END
    SET @G_SerialId = (SELECT NewId FROM @rSer);
    DELETE FROM @rCsAdd;
    INSERT INTO @rCsAdd EXEC Lots.ContainerSerial_Add @ContainerId = @G_Container, @SerializedPartId = @G_SerialId, @TrayPosition = @G_i, @AppUserId = @U;
    IF (SELECT Status FROM @rCsAdd) <> 1 BEGIN SET @ErrMsg = N'5G0 ContainerSerial_Add failed: ' + ISNULL((SELECT Message FROM @rCsAdd), N'?'); THROW 51000, @ErrMsg, 1; END
    SET @G_i = @G_i + 1;
END

DELETE FROM @rHold;
INSERT INTO @rHold EXEC Quality.Hold_Place @LotId = @G_Mach, @HoldTypeCodeId = @HoldQuality, @Reason = N'Demo: quality hold pending dimensional review', @AppUserId = @U;
IF (SELECT Status FROM @rHold) <> 1 BEGIN SET @ErrMsg = N'5G0 Hold_Place failed: ' + ISNULL((SELECT Message FROM @rHold), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_HoldId BIGINT = (SELECT NewId FROM @rHold);
PRINT N'    5G0-SER ready: machined=' + @G_MachName + N' (held), container=' + CAST(@G_Container AS NVARCHAR(20)) + N' (4 serials placed).';

-- ============================================================
-- RECEIVE: a Received 21001 pin LOT (purchased part). Received to MA1, where the
-- pin is eligible/consumed (Lot_Create enforces item-location eligibility, and no
-- part is eligible at the SHIPIN dock).
-- ============================================================
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_pin, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_MA1, @PieceCount = 100, @VendorLotNumber = N'PIN-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'RECEIVE pin Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @R_Pin NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

-- ============================================================
-- CROSS-CUT: pause + reject on the 6NA mach-out WIP LOT; downtime at the 6NA line.
-- ============================================================
PRINT N'--- cross-cutting exercisers: pause / reject / downtime ---';
DELETE FROM @rPause;
INSERT INTO @rPause EXEC Lots.LotPause_Place @LotId = @W_MoutMach, @LocationId = @L_6NA_MOUT, @PausedReason = N'Demo: waiting on engineering sign-off', @AppUserId = @U;
IF (SELECT Status FROM @rPause) <> 1 BEGIN SET @ErrMsg = N'LotPause_Place failed: ' + ISNULL((SELECT Message FROM @rPause), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @X_PauseId BIGINT = (SELECT NewId FROM @rPause);

DELETE FROM @rRej;
INSERT INTO @rRej EXEC Workorder.RejectEvent_Record @LotId = @W_MoutMach, @DefectCodeId = @DefectId, @Quantity = 2, @Remarks = N'Demo: minor surface defect', @AppUserId = @U;
IF (SELECT Status FROM @rRej) <> 1 BEGIN SET @ErrMsg = N'RejectEvent_Record failed: ' + ISNULL((SELECT Message FROM @rRej), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rDown;
INSERT INTO @rDown EXEC Oee.DowntimeEvent_Start @LocationId = @L_6NA, @DowntimeSourceCodeId = @DtSrc, @AppUserId = @U;
IF (SELECT Status FROM @rDown) <> 1 BEGIN SET @ErrMsg = N'DowntimeEvent_Start failed: ' + ISNULL((SELECT Message FROM @rDown), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @X_DowntimeId BIGINT = (SELECT NewId FROM @rDown);
PRINT N'    cross-cutting ready: pause=' + CAST(@X_PauseId AS NVARCHAR(20)) + N', reject 2 pcs, downtime=' + CAST(@X_DowntimeId AS NVARCHAR(20)) + N' at MA1-FP6NA.';

-- ============================================================
-- WHAT TO SMOKE
-- ============================================================
PRINT N'';
PRINT N'==================================================================';
PRINT N'  DEMO SEED READY - WHAT TO SMOKE  (operator DEV)';
PRINT N'==================================================================';
PRINT N'1) DIE CAST /shop-floor/die-cast : cell DC3-M01 has WIP cast ' + @W_DieCast + N' (12 pcs, tool DEMO-DC-6NA). 5G0 die is on DC1-M01.';
PRINT N'2) TRIM /shop-floor/trim : cast ' + @W_Trim + N' sits at TRIM1 -- trim it out to the 6NA line (MA1-FP6NA-MIN).';
PRINT N'3) MACHINING IN /shop-floor/machining-in (line MA1-FP6NA) : unworked arrival ' + @W_MinCast + N' waiting to be picked.';
PRINT N'4) MACHINING OUT /shop-floor/machining-out : machined ' + @W_MoutMachName + N' at MA1-FP6NA-MOUT (paused + 2-pc reject).';
PRINT N'5) ASSEMBLY (NON-SERIALIZED) /shop-floor/assembly-nonserialized (MA1-FP6NA-AFIN) : a machined 6NA-M LOT + studs/dowels staged -- open a container + complete trays of 6.';
PRINT N'6) SHIPPING /shop-floor/shipping : 6NA container ' + CAST(@ShipContainer AS NVARCHAR(20)) + N' already SHIPPED, AIM ' + ISNULL(@ShipAim, N'?') + N'. Received pin LOT ' + @R_Pin + N' at MA1 (purchased-part receipt).';
PRINT N'7) ASSEMBLY (SERIALIZED) /shop-floor/assembly-serialized (MA1-5GOF) : container ' + CAST(@G_Container AS NVARCHAR(20)) + N' has 4 serials from ' + @G_MachName + N'.';
PRINT N'8) HOLD MANAGEMENT /shop-floor/hold-management : release hold ' + CAST(@G_HoldId AS NVARCHAR(20)) + N' on 5G0 machined ' + @G_MachName + N'.';
PRINT N'9) DOWNTIME / SUPERVISOR : open downtime ' + CAST(@X_DowntimeId AS NVARCHAR(20)) + N' at MA1-FP6NA -- end it.';
PRINT N'10) LOT SEARCH / GENEALOGY / TRACE : trace the shipped 6NA container ' + CAST(@ShipContainer AS NVARCHAR(20)) + N' back through its FG + machined + casting LOTs.';
PRINT N'==================================================================';
GO
