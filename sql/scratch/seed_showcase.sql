-- ============================================================
-- seed_showcase.sql
-- SHOWCASE demo dataset for the Track & Trace capability deck. Self-contained:
-- idempotent transactional wipe + rebuild of connected threads via the real
-- production stored procs, then a showcase overlay (identity scrub + back-dated
-- report history + die shot counts) and a verification gate.
--
-- Derived from seed_demo.sql but FIXED for the reconciled location model
-- (MA1-FP6NA-AFIN -> -AOUT) and with the stale 5G0 serialized thread removed
-- (the 5GOF line no longer has a Machining-OUT terminal). Adds report-worthy
-- date spread the live seed_demo lacks (downtime across ~2 weeks; 4-week
-- production trend; die shot counts near/over limit).
--
-- NO hardcoded USE: runs against whatever DB sqlcmd is connected to. Run with -I
-- (Lots.* filtered indexes need QUOTED_IDENTIFIER ON). ASCII-only.
--
-- Threads built (terminal-mint model, 6NA oil-pump-housing line):
--   SHIP : 2x [cast -> trim -> mach-in -> mach-out mint machined] -> 24 machined
--          -> 4 trays of 6 -> container COMPLETE + SHIPPED (hero genealogy).
--   WIP  : a LOT staged at every terminal (die-cast / trim / mach-in unworked /
--          mach-out) + a machined LOT at the assembly cell. Mach-out LOT carries
--          a pause + reject.
--   RECEIVE : a Received purchased-pin LOT at MA1 (also the metrics carrier for
--             the back-dated line-performance production events).
--   Cross-cut: one open downtime at the 6NA line.
-- Overlay: identity scrub (no customer/OEM names), die shot counts, ~2 weeks of
--   closed downtime, a 4-week production trend, verification.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================
-- STEP 1: Idempotent transactional wipe (FK-safe order).
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
-- STEP 2: Die tool set (idempotent). One mounted production die drives the
-- thread; extra dies exist purely to populate the Shot Count report.
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @L_DC3M01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC3-M01');
DECLARE @ToolTypeDie      BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @CavActive        BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

-- ---- Production die: DC-OPH-01 @ DC3-M01 (drives the thread) ----
DECLARE @ToolIdOPH BIGINT;
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'DC-OPH-01')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolTypeDie, N'DC-OPH-01', N'Die - Oil Pump Housing', @ToolStatusActive, @U, SYSUTCDATETIME());
SET @ToolIdOPH = (SELECT Id FROM Tools.Tool WHERE Code = N'DC-OPH-01');
IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @ToolIdOPH)
    INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolIdOPH, 1, @CavActive, @U, SYSUTCDATETIME()), (@ToolIdOPH, 2, @CavActive, @U, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolIdOPH AND CellLocationId = @L_DC3M01 AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@ToolIdOPH, @L_DC3M01, SYSUTCDATETIME(), @U);

-- ---- Extra dies for the Shot Count report (no mount needed) ----
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, ShotLimit, CreatedByUserId, CreatedAt)
SELECT @ToolTypeDie, v.Code, v.Name, @ToolStatusActive, v.ShotCount, v.ShotLimit, @U, SYSUTCDATETIME()
FROM (VALUES
    (N'DC-FCV-01', N'Die - Front Cover',      92500, 100000),
    (N'DC-CAM-01', N'Die - Cam Holder',      101200, 100000),
    (N'DC-BRK-01', N'Die - Mounting Bracket', 61000, 150000),
    (N'DC-VLV-01', N'Die - Valve Cover',     138000, 150000)
) v(Code, Name, ShotCount, ShotLimit)
WHERE NOT EXISTS (SELECT 1 FROM Tools.Tool t WHERE t.Code = v.Code);

PRINT N'Step 2: die set ready (DC-OPH-01 mounted @ DC3-M01 + 4 report dies).';
GO

-- ============================================================
-- STEP 3: Build the threads. One contiguous batch (table variables persist).
-- Fail-fast: THROW on Status <> 1.
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @ErrMsg NVARCHAR(1000);

-- ---- Locations (by Code) ----
DECLARE @L_DC3M01     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC3-M01');
DECLARE @L_TRIM1      BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @L_6NA        BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @L_6NA_MIN    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN');
DECLARE @L_6NA_MOUT   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @L_6NA_AOUT   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');  -- was AFIN (reconciled)
DECLARE @L_MA1        BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');

-- ---- Items (by PartNumber; the 6NA oil-pump-housing family + fasteners + pin) ----
DECLARE @I_cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @I_mach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @I_fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @I_stud BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @I_dowel BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');
DECLARE @I_pin  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'21001 pin');

-- ---- Tool (mounted in Step 2) ----
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DC-OPH-01');
DECLARE @CavId  BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId ORDER BY CavityNumber);

-- ---- Code-table lookups ----
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OT_TrimOut      BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut' AND DeprecatedAt IS NULL);
DECLARE @OT_MachiningOut BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut' AND DeprecatedAt IS NULL);
-- TrimIn checkpoint template resolved BY ROLE from the casting's published route
-- (seq-2 Advance step). The route is DieCast->TrimIn->TrimOut->MachiningIn->MachiningOut;
-- the consume-mint's FIFO gate treats the lowest UNSATISFIED Advance step as "next-pending",
-- so a missing TrimIn checkpoint keeps TrimIn pending and starves MachiningOut_Mint.
DECLARE @OT_TrimIn BIGINT = (SELECT TOP 1 rs.OperationTemplateId
    FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @I_cast AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'TrimIn'
    ORDER BY rs.SequenceNumber);
DECLARE @DefectId    BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode ORDER BY Id);
DECLARE @DtSrc       BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

-- ---- Result-capture table variables ----
DECLARE @rLot   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rMove  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @rTrim  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMin   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rPE    TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMint  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
DECLARE @rTray  TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
DECLARE @rComp  TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @rShip  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @rPause TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rRej   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rDown  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

DECLARE @cast BIGINT, @mach BIGINT;

-- ============================================================
-- Stage purchased fasteners at the assembly cell (consumed by Assembly_CompleteTray).
-- ============================================================
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_stud, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_6NA_AOUT, @PieceCount = 40, @VendorLotNumber = N'STUD-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'stud stock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_dowel, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_6NA_AOUT, @PieceCount = 80, @VendorLotNumber = N'DOWEL-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'dowel stock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

-- ============================================================
-- SHIP: two cast->machine cycles (24 machined) -> 4 trays -> ship.
-- ============================================================
PRINT N'--- SHIP: cast x2 -> machine -> assemble 4 trays -> ship ---';

-- cycle 1
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'SHIP c1 cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'SHIP c1 move-trim failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rPE; INSERT INTO @rPE EXEC Workorder.ProductionEvent_Record @LotId = @cast, @OperationTemplateId = @OT_TrimIn, @ShotCount = 12, @AppUserId = @U, @TerminalLocationId = @L_TRIM1;
IF (SELECT Status FROM @rPE) <> 1 BEGIN SET @ErrMsg = N'TrimIn checkpoint failed: ' + ISNULL((SELECT Message FROM @rPE), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'SHIP c1 trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'SHIP c1 mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'SHIP c1 mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
SET @mach = (SELECT NewId FROM @rMint);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @mach, @ToLocationId = @L_6NA_AOUT, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'SHIP c1 move-aout failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- cycle 2
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000002', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'SHIP c2 cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'SHIP c2 move-trim failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rPE; INSERT INTO @rPE EXEC Workorder.ProductionEvent_Record @LotId = @cast, @OperationTemplateId = @OT_TrimIn, @ShotCount = 12, @AppUserId = @U, @TerminalLocationId = @L_TRIM1;
IF (SELECT Status FROM @rPE) <> 1 BEGIN SET @ErrMsg = N'TrimIn checkpoint failed: ' + ISNULL((SELECT Message FROM @rPE), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'SHIP c2 trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'SHIP c2 mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'SHIP c2 mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
SET @mach = (SELECT NewId FROM @rMint);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @mach, @ToLocationId = @L_6NA_AOUT, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'SHIP c2 move-aout failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- 4 trays of 6 -> container fills (4 x 6 = 24).
DECLARE @ShipContainer BIGINT, @tray INT = 1;
WHILE @tray <= 4
BEGIN
    DELETE FROM @rTray;
    INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_fg, @PieceCount = 6, @CellLocationId = @L_6NA_AOUT, @ClosureMethod = N'ByVision', @AppUserId = @U;
    IF (SELECT Status FROM @rTray) <> 1 BEGIN SET @ErrMsg = N'SHIP tray ' + CAST(@tray AS NVARCHAR(2)) + N' failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
    SET @ShipContainer = (SELECT ContainerId FROM @rTray);
    SET @tray = @tray + 1;
END

DELETE FROM @rComp;
INSERT INTO @rComp EXEC Lots.Container_Complete @ContainerId = @ShipContainer, @OperatorConfirmed = 1, @AppUserId = @U;
IF (SELECT Status FROM @rComp) <> 1 BEGIN SET @ErrMsg = N'SHIP Container_Complete failed: ' + ISNULL((SELECT Message FROM @rComp), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @ShipLabel BIGINT = (SELECT ShippingLabelId FROM @rComp);

DELETE FROM @rShip;
INSERT INTO @rShip EXEC Lots.Container_Ship @ShippingLabelId = @ShipLabel, @AppUserId = @U;
IF (SELECT Status FROM @rShip) <> 1 BEGIN SET @ErrMsg = N'SHIP Container_Ship failed: ' + ISNULL((SELECT Message FROM @rShip), N'?'); THROW 51000, @ErrMsg, 1; END
PRINT N'    SHIP complete: container ' + CAST(@ShipContainer AS NVARCHAR(20)) + N' shipped (hero genealogy).';

-- ============================================================
-- WIP: a LOT at every terminal + a machined LOT at the assembly cell.
-- ============================================================
PRINT N'--- WIP: staged at every terminal ---';

-- die-cast WIP (untouched cast at DC3-M01)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000003', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'WIP die-cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

-- trim WIP (cast moved to TRIM1, not trimmed out)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000004', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'WIP trim cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'WIP trim move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- machining-IN unworked WIP (cast trimmed to MA1-FP6NA-MIN, not picked)
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000005', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'WIP MIN cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'WIP MIN move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rPE; INSERT INTO @rPE EXEC Workorder.ProductionEvent_Record @LotId = @cast, @OperationTemplateId = @OT_TrimIn, @ShotCount = 12, @AppUserId = @U, @TerminalLocationId = @L_TRIM1;
IF (SELECT Status FROM @rPE) <> 1 BEGIN SET @ErrMsg = N'TrimIn checkpoint failed: ' + ISNULL((SELECT Message FROM @rPE), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'WIP MIN trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END

-- machining-OUT WIP (a fresh machined LOT parked at MOUT) -- carries pause + reject
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000006', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'WIP MOUT cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'WIP MOUT move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rPE; INSERT INTO @rPE EXEC Workorder.ProductionEvent_Record @LotId = @cast, @OperationTemplateId = @OT_TrimIn, @ShotCount = 12, @AppUserId = @U, @TerminalLocationId = @L_TRIM1;
IF (SELECT Status FROM @rPE) <> 1 BEGIN SET @ErrMsg = N'TrimIn checkpoint failed: ' + ISNULL((SELECT Message FROM @rPE), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'WIP MOUT trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'WIP MOUT mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'WIP MOUT mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @W_MoutMach BIGINT = (SELECT NewId FROM @rMint);

-- assembly-ready: one more machined LOT left AT the assembly cell
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_cast, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @L_DC3M01, @PieceCount = 12, @ToolId = @ToolId, @ToolCavityId = @CavId, @LotName = N'800000007', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'WIP AOUT cast failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
SET @cast = (SELECT NewId FROM @rLot);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'WIP AOUT move failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rPE; INSERT INTO @rPE EXEC Workorder.ProductionEvent_Record @LotId = @cast, @OperationTemplateId = @OT_TrimIn, @ShotCount = 12, @AppUserId = @U, @TerminalLocationId = @L_TRIM1;
IF (SELECT Status FROM @rPE) <> 1 BEGIN SET @ErrMsg = N'TrimIn checkpoint failed: ' + ISNULL((SELECT Message FROM @rPE), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rTrim; INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 12, @DestinationCellLocationId = @L_6NA_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1 BEGIN SET @ErrMsg = N'WIP AOUT trim failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMin; INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @cast, @LineLocationId = @L_6NA, @AppUserId = @U, @TerminalLocationId = @L_6NA_MIN;
IF (SELECT Status FROM @rMin) <> 1 BEGIN SET @ErrMsg = N'WIP AOUT mach-in failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END
DELETE FROM @rMint; INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @cast, @OperationTemplateId = @OT_MachiningOut, @PieceCount = 12, @AppUserId = @U, @TerminalLocationId = @L_6NA_MOUT;
IF (SELECT Status FROM @rMint) <> 1 BEGIN SET @ErrMsg = N'WIP AOUT mach-out failed: ' + ISNULL((SELECT Message FROM @rMint), N'?'); THROW 51000, @ErrMsg, 1; END
SET @mach = (SELECT NewId FROM @rMint);
DELETE FROM @rMove; INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @mach, @ToLocationId = @L_6NA_AOUT, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1 BEGIN SET @ErrMsg = N'WIP AOUT move-aout failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END
PRINT N'    WIP staged at every terminal.';

-- ============================================================
-- RECEIVE: a Received purchased-pin LOT at MA1.
-- ============================================================
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_pin, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @L_MA1, @PieceCount = 100, @VendorLotNumber = N'PIN-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1 BEGIN SET @ErrMsg = N'RECEIVE pin Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

-- ============================================================
-- CROSS-CUT: pause + reject on the mach-out WIP LOT; one open downtime at the line.
-- ============================================================
DELETE FROM @rPause;
INSERT INTO @rPause EXEC Lots.LotPause_Place @LotId = @W_MoutMach, @LocationId = @L_6NA_MOUT, @PausedReason = N'Waiting on engineering sign-off', @AppUserId = @U;
IF (SELECT Status FROM @rPause) <> 1 BEGIN SET @ErrMsg = N'LotPause_Place failed: ' + ISNULL((SELECT Message FROM @rPause), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rRej;
INSERT INTO @rRej EXEC Workorder.RejectEvent_Record @LotId = @W_MoutMach, @DefectCodeId = @DefectId, @Quantity = 2, @Remarks = N'Minor surface defect', @AppUserId = @U;
IF (SELECT Status FROM @rRej) <> 1 BEGIN SET @ErrMsg = N'RejectEvent_Record failed: ' + ISNULL((SELECT Message FROM @rRej), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rDown;
INSERT INTO @rDown EXEC Oee.DowntimeEvent_Start @LocationId = @L_6NA, @DowntimeSourceCodeId = @DtSrc, @AppUserId = @U;
IF (SELECT Status FROM @rDown) <> 1 BEGIN SET @ErrMsg = N'DowntimeEvent_Start failed: ' + ISNULL((SELECT Message FROM @rDown), N'?'); THROW 51000, @ErrMsg, 1; END
PRINT N'    cross-cut ready: pause + 2-pc reject + one open downtime at the line.';
GO

-- ============================================================
-- STEP 4: SHOWCASE OVERLAY -- identity scrub, shot counts, back-dated report
-- history (downtime ~2 weeks, production 4-week trend), verification.
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @DtSrc BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

-- ---- (A) IDENTITY SCRUB (display fields only; codes/PartNumbers unchanged) ----
UPDATE Location.Location SET Name = N'Riverside Casting Group' WHERE Code = N'MPP-ENT';
UPDATE Location.Location SET Name = N'Riverside Die Casting - Plant 1' WHERE Code = N'MPP-MAD';

UPDATE Parts.Item SET Description = v.d
FROM Parts.Item i
JOIN (VALUES
    (N'12270-6NA',       N'Oil Pump Housing - Raw Casting'),
    (N'12270-6NA-M',     N'Oil Pump Housing - Machined'),
    (N'12270-6NA -0001', N'Oil Pump Housing Assembly'),
    (N'12231-59B-0000',  N'Cam Holder, Intake #1 - Casting'),
    (N'12232-59B-0000',  N'Cam Holder, Intake #2 - Casting'),
    (N'1223A-59B -A0002',N'Cam-Rocker Holder Set'),
    (N'12241-59B-0000',  N'Cam Holder, Exhaust #1 - Casting'),
    (N'5G0-c',           N'Front Cover - Casting'),
    (N'5G0-SA',          N'Front Cover - Sub-Assembly'),
    (N'5G0-FG',          N'Front Cover - Finished Good'),
    (N'21001 pin',       N'Retaining Pin'),
    (N'90701-5R0-3000',  N'Dowel Pin 9x10'),
    (N'92900-06014-1B',  N'Stud Bolt M6x14'),
    (N'94301-08100',     N'Dowel Pin 8x10')
) v(pn, d) ON v.pn = i.PartNumber;

-- ---- (B) DIE SHOT COUNTS (idempotent; production die + report dies) ----
UPDATE Tools.Tool SET ShotCount = 48250,  ShotLimit = 100000 WHERE Code = N'DC-OPH-01';
UPDATE Tools.Tool SET ShotCount = 92500,  ShotLimit = 100000 WHERE Code = N'DC-FCV-01';
UPDATE Tools.Tool SET ShotCount = 101200, ShotLimit = 100000 WHERE Code = N'DC-CAM-01';
UPDATE Tools.Tool SET ShotCount = 61000,  ShotLimit = 150000 WHERE Code = N'DC-BRK-01';
UPDATE Tools.Tool SET ShotCount = 138000, ShotLimit = 150000 WHERE Code = N'DC-VLV-01';

-- ---- (C) BACK-DATED DOWNTIME (~2 weeks, closed, varied machines + reasons) ----
-- StartedAt = midnight-anchored day - DayAgo + StartHour; EndedAt = +DurMin.
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, StartedAt, EndedAt, DowntimeSourceCodeId, AppUserId, DurationMinutes, IsApproximate, CreatedAt)
SELECT
    loc.Id,
    rc.Id,
    DATEADD(MINUTE, v.StartHour * 60, DATEADD(DAY, -v.DayAgo, CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(3)))),
    DATEADD(MINUTE, v.StartHour * 60 + v.DurMin, DATEADD(DAY, -v.DayAgo, CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(3)))),
    @DtSrc, @U, v.DurMin, 0,
    DATEADD(MINUTE, v.StartHour * 60, DATEADD(DAY, -v.DayAgo, CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(3))))
FROM (VALUES
    (13, 2, 45,  N'DC1-M01', N'DC-0002'),
    (13, 9, 30,  N'DC1-M03', N'DC-0007'),
    (12, 6, 120, N'DC1-M02', N'DC-0003'),
    (11, 4, 25,  N'DC1-M05', N'DC-0007'),
    (10, 7, 60,  N'DC1-M01', N'DC-0004'),
    (10,14, 40,  N'DC1-M04', N'DC-0008'),
    ( 9, 3, 90,  N'DC1-M06', N'DC-0003'),
    ( 8, 5, 20,  N'DC1-M02', N'DC-0007'),
    ( 7, 8, 150, N'DC1-M03', N'DC-0002'),
    ( 6,11, 35,  N'DC1-M01', N'DC-0005'),
    ( 5, 2, 55,  N'DC1-M04', N'DC-0004'),
    ( 4,10, 75,  N'DC1-M05', N'DC-0003'),
    ( 3, 6, 30,  N'DC1-M06', N'DC-0008'),
    ( 3,13, 45,  N'DC1-M02', N'DC-0006'),
    ( 2, 4, 110, N'DC1-M01', N'DC-0002'),
    ( 1, 7, 25,  N'DC1-M03', N'DC-0007'),
    ( 1,15, 65,  N'DC1-M05', N'DC-0003'),
    ( 0, 5, 40,  N'DC1-M04', N'DC-0007')
) v(DayAgo, StartHour, DurMin, MachineCode, ReasonCode)
JOIN Location.Location loc ON loc.Code = v.MachineCode
JOIN Oee.DowntimeReasonCode rc ON rc.Code = v.ReasonCode;

-- ---- (D) BACK-DATED PRODUCTION (4-week trend by line; carrier = pin LOT so the
--          hero LOT's production history stays clean) ----
DECLARE @CarrierLot BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE ItemId = (SELECT Id FROM Parts.Item WHERE PartNumber = N'21001 pin') ORDER BY Id);
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, ScrapCount, AppUserId)
SELECT @CarrierLot, ot.Id,
    DATEADD(DAY, -(v.WeeksAgo * 7), SYSUTCDATETIME()),
    v.Produced, v.Scrap, @U
FROM (VALUES
    (3, N'DieCastShot',  1180, 42),
    (3, N'TrimOut',      1120, 18),
    (3, N'MachiningOut', 1090, 12),
    (2, N'DieCastShot',  1240, 38),
    (2, N'TrimOut',      1205, 22),
    (2, N'MachiningOut', 1160, 15),
    (1, N'DieCastShot',  1310, 51),
    (1, N'TrimOut',      1260, 20),
    (1, N'MachiningOut', 1215, 10),
    (0, N'DieCastShot',   640, 19),
    (0, N'TrimOut',       610,  9),
    (0, N'MachiningOut',  585,  6)
) v(WeeksAgo, TemplateCode, Produced, Scrap)
JOIN Parts.OperationTemplate ot ON ot.Code = v.TemplateCode AND ot.DeprecatedAt IS NULL;

PRINT N'Step 4: overlay applied (scrub + shot counts + downtime + production trend).';
GO

-- ============================================================
-- STEP 5: VERIFICATION (hard-fail on any gap or forbidden identifier).
-- ============================================================
DECLARE @bad INT = (
    SELECT COUNT(*) FROM (
        SELECT Name AS s FROM Location.Location
        UNION ALL SELECT Description FROM Parts.Item
        UNION ALL SELECT PartNumber FROM Parts.Item
        UNION ALL SELECT Name FROM Tools.Tool
    ) x WHERE x.s LIKE N'%Honda%' OR x.s LIKE N'%Madison%' OR x.s LIKE N'%MPP%' OR x.s LIKE N'%AIM%');
IF @bad > 0 THROW 50001, 'Forbidden customer/OEM identifier present in display data.', 1;

DECLARE @shipped INT = (SELECT COUNT(*) FROM Lots.Container c JOIN Lots.ContainerStatusCode s ON s.Id = c.ContainerStatusCodeId WHERE s.Code = N'Shipped');
IF @shipped < 1 THROW 50002, 'No shipped container (hero genealogy missing).', 1;

DECLARE @dtDays INT = (SELECT COUNT(DISTINCT CAST(StartedAt AS DATE)) FROM Oee.DowntimeEvent);
IF @dtDays < 5 THROW 50003, 'Downtime history spans < 5 distinct days.', 1;

DECLARE @prodWeeks INT = (SELECT COUNT(DISTINCT DATEDIFF(WEEK, 0, EventAt)) FROM Workorder.ProductionEvent);
IF @prodWeeks < 3 THROW 50004, 'Production history spans < 3 weeks (line-performance trend too flat).', 1;

DECLARE @dies INT = (SELECT COUNT(*) FROM Tools.Tool WHERE ShotCount > 0);
IF @dies < 3 THROW 50005, 'Fewer than 3 dies with shot counts (shot-count report too sparse).', 1;

PRINT N'';
PRINT N'==================================================================';
PRINT N'  SHOWCASE SEED READY';
PRINT N'==================================================================';
PRINT N'  Shipped hero container + WIP at every terminal + received pin LOT.';
PRINT N'  Downtime across ' + CAST(@dtDays AS NVARCHAR(4)) + N' days; production across ' + CAST(@prodWeeks AS NVARCHAR(4)) + N' weeks; ' + CAST(@dies AS NVARCHAR(4)) + N' dies with shot counts.';
PRINT N'  Identity scrub verified (no customer/OEM identifiers).';
PRINT N'==================================================================';
GO
