-- ============================================================
-- seed_demo.sql
-- Continuous Demo Seed Dataset (Task 2). Idempotent transactional wipe +
-- rebuild of the connected matrix threads (6MA / 5G0 / RD-BRKT) via the
-- production stored procs, on top of the clean parts config loaded by
-- sql/seeds (Task 1: 020_seed_items.sql + 029_seed_item_routes.sql).
--
-- NOT a migration, NOT a test. Re-runnable any number of times: the wipe
-- block deletes ALL Lots/Workorder/Oee/Quality transactional data (FK-safe
-- order), then rebuilds identical thread SHAPES (row counts) via the real
-- mutation procs, so genealogy/closure/consumption/audit are authentic,
-- not hand-faked. Config (Parts.*, Location.*, Tools.Tool/ToolCavity code
-- tables) is left intact; only the ToolAssignment MOUNT + two rename BOMs
-- this script itself creates are additive/idempotent (guarded, not wiped).
--
-- Usage:  sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_demo.sql
--         (run AFTER Reset-DevDatabase.ps1; -I matters -- Lots.* carry
--          filtered indexes -> Msg 1934 without it)
--
-- Topology (RESOLVED 2026-07-06; machining model updated for commits
-- 348762e/1e46c60 "Machining IN = unworked arrivals, drop BOM consumption"):
--   6MA-C cast    DC1-M01 (die-cast, tool mounted) -> trim TRIM1 -> MA1-FPRPY-MIN
--   Machining IN  MA1-FPRPY  RecordPick marks the cast LOT "worked" (NO rename/
--                 consume post-rework -- the LOT stays 6MA-C).
--   Machining OUT MA1-FPRPY-MOUT: the machined 6MA-M LOT is minted here via
--                 Lot_Create (no proc renames cast->machined anymore), then
--                 extract-one split -> children (6MA-M) -> AFIN.
--   Assembly      MA1-FPRPY-AFIN (non-serialized; consumes 6MA-M + PIN-A -> 6MA)
--   5G0-C cast    DC1-M02 -> MA1-5GOF (line); RecordPick; machined 5G0-M minted
--                 line-resident at MA1-5GOF -> serialized placement (ASER screen
--                 zones to the line). FG-LOT completion deferred (A4).
--   RD-BRKT       SHIPIN (receiving) -> SHIPOUT (shipping); pass-through,
--                 no Container/AIM involved.
--
-- GENEALOGY NOTE: post-rework NO proc builds the cast->machined edge (the old
-- MachiningIn_PickAndConsume did). The authentic proc-built genealogy chain here
-- is machined LOT -> split sublots -> FG LOT -> container. The cast LOTs are real,
-- audited WIP but are not genealogy-linked to the machined LOTs. See report.
--
-- All locations/parts/users resolved BY CODE / natural key, never a
-- hardcoded Id (survives identity reseeds). ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
USE MPP_MES_Dev;
GO

-- ============================================================
-- STEP 1: Idempotent transactional wipe (FK-safe order).
-- Table set verified against:
--   SELECT name FROM sys.tables WHERE schema_name(schema_id) IN
--   ('Lots','Workorder','Oee','Quality')            (2026-07-06)
-- AimShipperIdPool release MUST run BEFORE Lots.Container is deleted
-- (FK_AimPool_Container references Container.Id -- deleting a still-
-- referenced Container row throws Msg 547; this is a deliberate reorder
-- vs. the brief's literal listing, which released the pool AFTER the
-- Container delete).
-- ============================================================
DELETE FROM Workorder.ConsumptionEvent;
DELETE FROM Workorder.ProductionEventValue;
DELETE FROM Workorder.ProductionEvent;
DELETE FROM Workorder.RejectEvent;
DELETE FROM Oee.DowntimeEvent;
DELETE FROM Quality.HoldEvent;
DELETE FROM Lots.PauseEvent;

-- Release AIM pool claims BEFORE any Container delete (FK order).
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
-- STEP 2: Die-cast tool mounts (idempotent -- guarded by Code / CellLocationId,
-- NOT wiped above; Tools.* is equipment config, mirrors the design doc's
-- "existing definitions stay").
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');

DECLARE @L_DC1M01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @L_DC1M02 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M02');

DECLARE @ToolTypeDie      BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @CavActive        BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

-- ---- DEMO-DC-6MA @ DC1-M01 ----
DECLARE @ToolId6MA BIGINT;
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'DEMO-DC-6MA')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolTypeDie, N'DEMO-DC-6MA', N'Demo Die - 6MA Cam Holder', @ToolStatusActive, @U, SYSUTCDATETIME());
SET @ToolId6MA = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-6MA');

IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @ToolId6MA)
    INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolId6MA, 1, @CavActive, @U, SYSUTCDATETIME()),
           (@ToolId6MA, 2, @CavActive, @U, SYSUTCDATETIME());

IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolId6MA AND CellLocationId = @L_DC1M01 AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@ToolId6MA, @L_DC1M01, SYSUTCDATETIME(), @U);

DECLARE @CavId6MA BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId6MA ORDER BY CavityNumber);

-- ---- DEMO-DC-5G0 @ DC1-M02 ----
DECLARE @ToolId5G0 BIGINT;
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'DEMO-DC-5G0')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolTypeDie, N'DEMO-DC-5G0', N'Demo Die - 5G0 Front Cover', @ToolStatusActive, @U, SYSUTCDATETIME());
SET @ToolId5G0 = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-5G0');

IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @ToolId5G0)
    INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
    VALUES (@ToolId5G0, 1, @CavActive, @U, SYSUTCDATETIME()),
           (@ToolId5G0, 2, @CavActive, @U, SYSUTCDATETIME());

IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolId5G0 AND CellLocationId = @L_DC1M02 AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@ToolId5G0, @L_DC1M02, SYSUTCDATETIME(), @U);

DECLARE @CavId5G0 BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId5G0 ORDER BY CavityNumber);

PRINT N'Step 2: die-cast tool mounts ready (DEMO-DC-6MA @ DC1-M01, DEMO-DC-5G0 @ DC1-M02).';
GO

-- ============================================================
-- STEP 3: Machining-IN rename BOMs (idempotent, guarded).
-- A single-line published BOM whose only child is the cast Item at QtyPer=1,
-- parented by the machined Item (6MA-M<-6MA-C x1, 5G0-M<-5G0-C x1). Post-rework
-- NO proc CONSUMES these -- they now drive the Machining IN WIP-queue read's
-- HasRenameBom hint (Lot_GetWipQueueByLocation) so the screen flags a cast LOT as
-- "renames to a machined part". DISTINCT from the 020-seeded assembly BOMs
-- (6MA<-6MA-M+PIN-A, 5G0<-5G0-M). Created via the production Bom_Create/
-- BomLine_Add/Bom_Publish procs -- not raw INSERT.
-- ============================================================
DECLARE @U2 BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @I_6MAC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-C');
DECLARE @I_6MAM BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-M');
DECLARE @I_5G0C BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-C');
DECLARE @I_5G0M BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-M');
DECLARE @UomEA  BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');

DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_6MAM AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc;
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId = @I_6MAM, @AppUserId = @U2;
    DECLARE @RenameBom6MA BIGINT = (SELECT NewId FROM @bc);
    DELETE FROM @bl;
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId = @RenameBom6MA, @ChildItemId = @I_6MAC, @QtyPer = 1, @UomId = @UomEA, @AppUserId = @U2;
    DELETE FROM @bp;
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id = @RenameBom6MA, @AppUserId = @U2;
END

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_5G0M AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc;
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId = @I_5G0M, @AppUserId = @U2;
    DECLARE @RenameBom5G0 BIGINT = (SELECT NewId FROM @bc);
    DELETE FROM @bl;
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId = @RenameBom5G0, @ChildItemId = @I_5G0C, @QtyPer = 1, @UomId = @UomEA, @AppUserId = @U2;
    DELETE FROM @bp;
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id = @RenameBom5G0, @AppUserId = @U2;
END

PRINT N'Step 3: machining-in rename BOMs ready (6MA-M<-6MA-C x1, 5G0-M<-5G0-C x1).';
GO

-- ============================================================
-- STEP 4: Build the threads.
-- One contiguous batch (table variables must persist across all captures).
-- Failure pattern: after each capture, check Status and RAISERROR via the
-- shared @ErrMsg variable and THROW (not RAISERROR -- RAISERROR does not accept
-- a scalar subquery as an argument, confirmed empirically, AND does not abort
-- batch execution the way this fail-fast orchestration script needs; THROW does).
-- The project's "RAISERROR not THROW" convention governs stored-proc CATCH
-- blocks (FDS-11-011); this is a standalone scratch script, not a proc.
-- ============================================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @ErrMsg NVARCHAR(1000);

-- ---- Locations (by Code) ----
DECLARE @L_DC1M01      BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @L_DC1M02      BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M02');
DECLARE @L_TRIM1       BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @L_FPRPY       BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY');
DECLARE @L_FPRPY_MIN   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN');
DECLARE @L_FPRPY_MOUT  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @L_FPRPY_AFIN  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @L_5GOF        BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @L_5GOF_MIN    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @L_5GOF_MOUT   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @L_5GOF_ASER   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-ASER');
DECLARE @L_SHIPIN      BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPIN');
DECLARE @L_SHIPOUT     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'SHIPOUT');

-- ---- Items (by PartNumber) ----
DECLARE @I_6MAC   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-C');
DECLARE @I_6MAM   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-M');
DECLARE @I_6MA    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA');
DECLARE @I_PINA   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PIN-A');
DECLARE @I_5G0C   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-C');
DECLARE @I_5G0M   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-M');
DECLARE @I_5G0    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0');
DECLARE @I_RDBRKT BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RD-BRKT');

-- ---- Tools (mounted in Step 2) ----
DECLARE @ToolId6MA BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-6MA');
DECLARE @CavId6MA  BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId6MA ORDER BY CavityNumber);
DECLARE @ToolId5G0 BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DEMO-DC-5G0');
DECLARE @CavId5G0  BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @ToolId5G0 ORDER BY CavityNumber);

-- ---- Code-table lookups ----
DECLARE @OriginManufactured BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OriginReceived     BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OT_TrimOut         BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @OT_MachiningOut    BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');
DECLARE @CC_6MA             BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @I_6MA AND DeprecatedAt IS NULL);
DECLARE @CC_5G0             BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @I_5G0 AND DeprecatedAt IS NULL);
DECLARE @HoldTypeQuality    BIGINT = (SELECT Id FROM Quality.HoldTypeCode WHERE Code = N'Quality');
DECLARE @DefectCodeId       BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);

-- ---- Result-capture table variables (one shape per proc signature) ----
DECLARE @rLot   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rMove  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @rTrim  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMin   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);   -- MachiningIn_RecordPick status row (NewId = ProductionEventId)
DECLARE @rSplit TABLE (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
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

-- ============================================================
-- 6MA THREAD A: one COMPLETED + SHIPPED run
-- ============================================================
PRINT N'--- 6MA thread A: cast -> trim -> machine -> split -> assemble -> ship ---';

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAC, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId6MA, @ToolCavityId = @CavId6MA, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-A cast Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @A_Cast BIGINT = (SELECT NewId FROM @rLot);

DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @A_Cast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'6MA-A move to TRIM1 failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rTrim;
INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @A_Cast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 24, @ScrapCount = 0, @DestinationCellLocationId = @L_FPRPY_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1
BEGIN SET @ErrMsg = N'6MA-A TrimOut_Record failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END

-- Machining IN: record the pick on the cast LOT (marks it "worked" -> drops off the
-- unworked-arrivals queue). Post-rework (commits 348762e/1e46c60) this NO LONGER
-- consumes/renames -- the cast LOT stays 6MA-C at the line. FDS-05-033.
DELETE FROM @rMin;
INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @A_Cast, @LineLocationId = @L_FPRPY, @AppUserId = @U, @TerminalLocationId = @L_FPRPY_MIN;
IF (SELECT Status FROM @rMin) <> 1
BEGIN SET @ErrMsg = N'6MA-A MachiningIn_RecordPick failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END

-- Machining OUT parent: mint the MACHINED 6MA-M LOT at MOUT. No proc renames the
-- cast LOT into the machined Item post-rework, so the split parent (which Assembly
-- must consume as 6MA-M) is minted directly here -- mirrors test 070's fixture.
-- NULL Tool/Cavity (machined part, B13). See report: cast->machined genealogy edge
-- is not built by any current proc.
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAM, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_FPRPY_MOUT, @PieceCount = 24, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-A machined Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @A_Machined BIGINT = (SELECT NewId FROM @rLot);

DECLARE @A_SplitJson NVARCHAR(MAX) = N'[{"pieceCount":12,"destinationLocationId":' + CAST(@L_FPRPY_AFIN AS NVARCHAR(20))
    + N'},{"pieceCount":12,"destinationLocationId":' + CAST(@L_FPRPY_AFIN AS NVARCHAR(20)) + N'}]';
DELETE FROM @rSplit;
INSERT INTO @rSplit EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @A_Machined, @OperationTemplateId = @OT_MachiningOut, @SplitChildrenJson = @A_SplitJson, @AppUserId = @U;
IF NOT EXISTS (SELECT 1 FROM @rSplit WHERE Status = 1)
BEGIN SET @ErrMsg = N'6MA-A MachiningOut_RecordSplit failed: ' + ISNULL((SELECT TOP 1 Message FROM @rSplit), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_PINA, @LotOriginTypeId = @OriginReceived, @CurrentLocationId = @L_FPRPY_AFIN, @PieceCount = 48, @VendorLotNumber = N'PINA-VEND-A001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-A PIN-A stock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rTray;
INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_6MA, @PieceCount = 12, @CellLocationId = @L_FPRPY_AFIN, @AppUserId = @U;
IF (SELECT Status FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'6MA-A Assembly_CompleteTray (tray 1) failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @A_Container BIGINT = (SELECT ContainerId FROM @rTray);

DELETE FROM @rTray;
INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_6MA, @PieceCount = 12, @CellLocationId = @L_FPRPY_AFIN, @AppUserId = @U;
IF (SELECT Status FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'6MA-A Assembly_CompleteTray (tray 2) failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
IF (SELECT ContainerFull FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'6MA-A container did not report full after 2 trays.'; THROW 51000, @ErrMsg, 1; END

DELETE FROM @rComp;
INSERT INTO @rComp EXEC Lots.Container_Complete @ContainerId = @A_Container, @OperatorConfirmed = 1, @AppUserId = @U;
IF (SELECT Status FROM @rComp) <> 1
BEGIN SET @ErrMsg = N'6MA-A Container_Complete failed: ' + ISNULL((SELECT Message FROM @rComp), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @A_ShipLabel BIGINT = (SELECT ShippingLabelId FROM @rComp);
DECLARE @A_AimId NVARCHAR(50) = (SELECT AimShipperId FROM @rComp);

DELETE FROM @rShip;
INSERT INTO @rShip EXEC Lots.Container_Ship @ShippingLabelId = @A_ShipLabel, @AppUserId = @U;
IF (SELECT Status FROM @rShip) <> 1
BEGIN SET @ErrMsg = N'6MA-A Container_Ship failed: ' + ISNULL((SELECT Message FROM @rShip), N'?'); THROW 51000, @ErrMsg, 1; END

PRINT N'    6MA-A complete: container ' + CAST(@A_Container AS NVARCHAR(20)) + N' shipped, AIM ' + ISNULL(@A_AimId, N'?') + N'.';

-- ============================================================
-- 6MA THREAD B: WIP at every terminal (die-cast, trim, machining-out, assembly)
-- ============================================================
PRINT N'--- 6MA thread B: WIP staged at every terminal ---';

-- B-a: WIP cast LOT sitting at DC1-M01 (die-cast screen WIP; untouched).
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAC, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId6MA, @ToolCavityId = @CavId6MA, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B die-cast WIP Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_CastAtDC1 BIGINT = (SELECT NewId FROM @rLot);
DECLARE @B_CastAtDC1Name NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

-- B-b: WIP cast LOT sitting at TRIM1 (trim screen WIP; moved but not trimmed out).
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAC, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId6MA, @ToolCavityId = @CavId6MA, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B trim WIP Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_CastAtTrim BIGINT = (SELECT NewId FROM @rLot);
DECLARE @B_CastAtTrimName NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @B_CastAtTrim, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'6MA-B move to TRIM1 failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- B-c: WIP machined LOT sitting at MA1-FPRPY-MOUT, NOT split (Machining OUT screen WIP).
-- Also carries the pause + reject cross-cutting exercisers (Step 6).
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAC, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId6MA, @ToolCavityId = @CavId6MA, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B MOUT-WIP cast Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_MoutCast BIGINT = (SELECT NewId FROM @rLot);

DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @B_MoutCast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'6MA-B MOUT-WIP move to TRIM1 failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rTrim;
INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @B_MoutCast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 24, @ScrapCount = 0, @DestinationCellLocationId = @L_FPRPY_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1
BEGIN SET @ErrMsg = N'6MA-B MOUT-WIP TrimOut_Record failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END

-- Record the pick on the cast LOT (marks worked), then mint the machined 6MA-M
-- WIP LOT AT MOUT -- this is the live Machining OUT extract-one subject.
DELETE FROM @rMin;
INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @B_MoutCast, @LineLocationId = @L_FPRPY, @AppUserId = @U, @TerminalLocationId = @L_FPRPY_MIN;
IF (SELECT Status FROM @rMin) <> 1
BEGIN SET @ErrMsg = N'6MA-B MOUT-WIP MachiningIn_RecordPick failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAM, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_FPRPY_MOUT, @PieceCount = 24, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B MOUT-WIP machined Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_MoutMachined BIGINT = (SELECT NewId FROM @rLot);
DECLARE @B_MoutMachinedName NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

-- B-d: WIP at assembly (AFIN): 6MA-M sublots + PIN-A staged, one tray closed, one to go.
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAC, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId6MA, @ToolCavityId = @CavId6MA, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B AFIN-WIP cast Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_AfinCast BIGINT = (SELECT NewId FROM @rLot);

DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @B_AfinCast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'6MA-B AFIN-WIP move to TRIM1 failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rTrim;
INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @B_AfinCast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 24, @ScrapCount = 0, @DestinationCellLocationId = @L_FPRPY_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1
BEGIN SET @ErrMsg = N'6MA-B AFIN-WIP TrimOut_Record failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rMin;
INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @B_AfinCast, @LineLocationId = @L_FPRPY, @AppUserId = @U, @TerminalLocationId = @L_FPRPY_MIN;
IF (SELECT Status FROM @rMin) <> 1
BEGIN SET @ErrMsg = N'6MA-B AFIN-WIP MachiningIn_RecordPick failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAM, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_FPRPY_MOUT, @PieceCount = 24, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B AFIN-WIP machined Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_AfinMachined BIGINT = (SELECT NewId FROM @rLot);

DECLARE @B_SplitJson NVARCHAR(MAX) = N'[{"pieceCount":12,"destinationLocationId":' + CAST(@L_FPRPY_AFIN AS NVARCHAR(20))
    + N'},{"pieceCount":12,"destinationLocationId":' + CAST(@L_FPRPY_AFIN AS NVARCHAR(20)) + N'}]';
DELETE FROM @rSplit;
INSERT INTO @rSplit EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @B_AfinMachined, @OperationTemplateId = @OT_MachiningOut, @SplitChildrenJson = @B_SplitJson, @AppUserId = @U;
IF NOT EXISTS (SELECT 1 FROM @rSplit WHERE Status = 1)
BEGIN SET @ErrMsg = N'6MA-B MachiningOut_RecordSplit failed: ' + ISNULL((SELECT TOP 1 Message FROM @rSplit), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_PINA, @LotOriginTypeId = @OriginReceived, @CurrentLocationId = @L_FPRPY_AFIN, @PieceCount = 48, @VendorLotNumber = N'PINA-VEND-B001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B PIN-A stock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rTray;
INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @I_6MA, @PieceCount = 12, @CellLocationId = @L_FPRPY_AFIN, @AppUserId = @U;
IF (SELECT Status FROM @rTray) <> 1
BEGIN SET @ErrMsg = N'6MA-B Assembly_CompleteTray (tray 1 of 2, container left open) failed: ' + ISNULL((SELECT Message FROM @rTray), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_OpenContainer BIGINT = (SELECT ContainerId FROM @rTray);
IF (SELECT ContainerFull FROM @rTray) <> 0
BEGIN SET @ErrMsg = N'6MA-B open-container WIP unexpectedly reported full after 1 tray.'; THROW 51000, @ErrMsg, 1; END

-- B-e: UNWORKED arrival at Machining IN -- a cast LOT trimmed out to MA1-FPRPY-MIN
-- but NOT yet picked, so the Machining IN unworked-arrivals queue has a live LOT
-- to pick (every other cast LOT above was RecordPick'd and has dropped off the queue).
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_6MAC, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M01, @PieceCount = 24, @ToolId = @ToolId6MA, @ToolCavityId = @CavId6MA, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'6MA-B MIN-WIP cast Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @B_MinCast BIGINT = (SELECT NewId FROM @rLot);
DECLARE @B_MinCastName NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @B_MinCast, @ToLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'6MA-B MIN-WIP move to TRIM1 failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rTrim;
INSERT INTO @rTrim EXEC Workorder.TrimOut_Record @ParentLotId = @B_MinCast, @OperationTemplateId = @OT_TrimOut, @ShotCount = 24, @ScrapCount = 0, @DestinationCellLocationId = @L_FPRPY_MIN, @SourceLocationId = @L_TRIM1, @AppUserId = @U;
IF (SELECT Status FROM @rTrim) <> 1
BEGIN SET @ErrMsg = N'6MA-B MIN-WIP TrimOut_Record failed: ' + ISNULL((SELECT Message FROM @rTrim), N'?'); THROW 51000, @ErrMsg, 1; END

PRINT N'    6MA-B WIP ready: die-cast=' + CAST(@B_CastAtDC1 AS NVARCHAR(20)) + N', trim=' + CAST(@B_CastAtTrim AS NVARCHAR(20))
    + N', mach-in unworked=' + CAST(@B_MinCast AS NVARCHAR(20)) + N' (' + @B_MinCastName + N')'
    + N', mach-out=' + CAST(@B_MoutMachined AS NVARCHAR(20)) + N' (' + @B_MoutMachinedName + N'), open container=' + CAST(@B_OpenContainer AS NVARCHAR(20)) + N'.';

-- ============================================================
-- 5G0 THREAD: serialized variant, mid-flow + active hold
-- ============================================================
PRINT N'--- 5G0 thread: cast -> machine -> mid-flow stop -> serialized placement + hold ---';

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_5G0C, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_DC1M02, @PieceCount = 48, @ToolId = @ToolId5G0, @ToolCavityId = @CavId5G0, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'5G0 cast Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_Cast BIGINT = (SELECT NewId FROM @rLot);

-- NOTE (2026-07-06, concurrent with this task): the 5GOF terminals are
-- "dedicated-flavor" (FDS-02-010) -- every terminal's session zones to its
-- PARENT LINE (Location.Terminal_GetByIpAddress: ZoneLocationId = ParentLocationId),
-- and the Machining IN/OUT/Assembly-Serialized screens all query WIP/containers
-- by an EXACT LocationId match on that zone (Lot_GetWipQueueByLocation,
-- Container.getOpenByCell -- no ancestor walk). So the LOT must live AT the LINE
-- (MA1-5GOF), not the individual MIN/MOUT/ASER cells, to be visible to the real
-- screens -- this is exactly the "line-deposit model" commit 0b33c42 just fixed
-- eligibility for. The FPRPY (6MA) terminals have no such screen/zone wiring
-- deployed yet (no DefaultScreen rows), so the 6MA thread above intentionally
-- keeps cell-level targeting per the RESOLVED topology instruction; see report
-- concerns.
DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @G_Cast, @ToLocationId = @L_5GOF, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'5G0 move to MA1-5GOF failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

-- Record the pick on the cast LOT at the line (marks worked). Post-rework this no
-- longer renames/consumes; the machined LOT is minted separately below.
DELETE FROM @rMin;
INSERT INTO @rMin EXEC Workorder.MachiningIn_RecordPick @LotId = @G_Cast, @LineLocationId = @L_5GOF, @AppUserId = @U, @TerminalLocationId = @L_5GOF_MIN;
IF (SELECT Status FROM @rMin) <> 1
BEGIN SET @ErrMsg = N'5G0 MachiningIn_RecordPick failed: ' + ISNULL((SELECT Message FROM @rMin), N'?'); THROW 51000, @ErrMsg, 1; END

-- Mint the machined 5G0-M LOT AT @L_5GOF (line-resident) -- the 5GOF terminals zone
-- to the line and the Machining OUT + Assembly Serialized screens read WIP/containers
-- by exact line match (commit 0b33c42's line-deposit model). 5G0-M is eligible at
-- MA1-5GOF. This LOT is the serials' producing LOT + the hold subject.
DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_5G0M, @LotOriginTypeId = @OriginManufactured, @CurrentLocationId = @L_5GOF, @PieceCount = 48, @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'5G0 machined Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_Machined BIGINT = (SELECT NewId FROM @rLot);
DECLARE @G_MachinedName NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

DELETE FROM @rConOp;
INSERT INTO @rConOp EXEC Lots.Container_Open @ItemId = @I_5G0, @ContainerConfigId = @CC_5G0, @CellLocationId = @L_5GOF, @AppUserId = @U;
IF (SELECT Status FROM @rConOp) <> 1
BEGIN SET @ErrMsg = N'5G0 Container_Open failed: ' + ISNULL((SELECT Message FROM @rConOp), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_Container BIGINT = (SELECT NewId FROM @rConOp);

DECLARE @G_i INT = 1;
DECLARE @G_SerialId BIGINT, @G_SerialNumber NVARCHAR(50), @G_LastSerial NVARCHAR(50);
WHILE @G_i <= 4
BEGIN
    DELETE FROM @rSer;
    INSERT INTO @rSer EXEC Lots.SerializedPart_Mint @ItemId = @I_5G0, @ProducingLotId = @G_Machined, @AppUserId = @U;
    IF (SELECT Status FROM @rSer) <> 1
    BEGIN SET @ErrMsg = N'5G0 SerializedPart_Mint failed: ' + ISNULL((SELECT Message FROM @rSer), N'?'); THROW 51000, @ErrMsg, 1; END
    SET @G_SerialId = (SELECT NewId FROM @rSer);
    SET @G_SerialNumber = (SELECT SerialNumber FROM @rSer);
    SET @G_LastSerial = @G_SerialNumber;

    DELETE FROM @rCsAdd;
    INSERT INTO @rCsAdd EXEC Lots.ContainerSerial_Add @ContainerId = @G_Container, @SerializedPartId = @G_SerialId, @TrayPosition = @G_i, @AppUserId = @U;
    IF (SELECT Status FROM @rCsAdd) <> 1
    BEGIN SET @ErrMsg = N'5G0 ContainerSerial_Add failed: ' + ISNULL((SELECT Message FROM @rCsAdd), N'?'); THROW 51000, @ErrMsg, 1; END

    SET @G_i = @G_i + 1;
END

DELETE FROM @rHold;
INSERT INTO @rHold EXEC Quality.Hold_Place @LotId = @G_Machined, @HoldTypeCodeId = @HoldTypeQuality, @Reason = N'Demo: quality hold pending dimensional review', @AppUserId = @U;
IF (SELECT Status FROM @rHold) <> 1
BEGIN SET @ErrMsg = N'5G0 Hold_Place failed: ' + ISNULL((SELECT Message FROM @rHold), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @G_HoldId BIGINT = (SELECT NewId FROM @rHold);

PRINT N'    5G0 ready: machined=' + CAST(@G_Machined AS NVARCHAR(20)) + N' (' + @G_MachinedName + N', held), container=' + CAST(@G_Container AS NVARCHAR(20)) + N' (4 serials placed).';

-- ============================================================
-- RD-BRKT THREAD: pass-through (received -> shipped, no processing)
-- ============================================================
PRINT N'--- RD-BRKT thread: received -> shipped pass-through ---';

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_RDBRKT, @LotOriginTypeId = @OriginReceived, @CurrentLocationId = @L_SHIPIN, @PieceCount = 100, @VendorLotNumber = N'RDBRKT-VEND-0001', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'RD-BRKT received-dock Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @R_Received BIGINT = (SELECT NewId FROM @rLot);
DECLARE @R_ReceivedName NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

DELETE FROM @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @I_RDBRKT, @LotOriginTypeId = @OriginReceived, @CurrentLocationId = @L_SHIPIN, @PieceCount = 100, @VendorLotNumber = N'RDBRKT-VEND-0002', @AppUserId = @U;
IF (SELECT Status FROM @rLot) <> 1
BEGIN SET @ErrMsg = N'RD-BRKT ship-thread Lot_Create failed: ' + ISNULL((SELECT Message FROM @rLot), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @R_Shipped BIGINT = (SELECT NewId FROM @rLot);
DECLARE @R_ShippedName NVARCHAR(50) = (SELECT MintedLotName FROM @rLot);

DELETE FROM @rMove;
INSERT INTO @rMove EXEC Lots.Lot_MoveTo @LotId = @R_Shipped, @ToLocationId = @L_SHIPOUT, @AppUserId = @U;
IF (SELECT Status FROM @rMove) <> 1
BEGIN SET @ErrMsg = N'RD-BRKT move to SHIPOUT failed: ' + ISNULL((SELECT Message FROM @rMove), N'?'); THROW 51000, @ErrMsg, 1; END

PRINT N'    RD-BRKT ready: on dock=' + @R_ReceivedName + N', shipped=' + @R_ShippedName + N'.';

-- ============================================================
-- CROSS-CUTTING EXERCISERS: pause, reject, downtime
-- ============================================================
PRINT N'--- cross-cutting exercisers: pause / reject / downtime ---';

DELETE FROM @rPause;
INSERT INTO @rPause EXEC Lots.LotPause_Place @LotId = @B_MoutMachined, @LocationId = @L_FPRPY_MOUT, @PausedReason = N'Demo: waiting on engineering sign-off', @AppUserId = @U;
IF (SELECT Status FROM @rPause) <> 1
BEGIN SET @ErrMsg = N'LotPause_Place failed: ' + ISNULL((SELECT Message FROM @rPause), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @X_PauseId BIGINT = (SELECT NewId FROM @rPause);

DELETE FROM @rRej;
INSERT INTO @rRej EXEC Workorder.RejectEvent_Record @LotId = @B_MoutMachined, @DefectCodeId = @DefectCodeId, @Quantity = 2, @Remarks = N'Demo: minor surface defect', @AppUserId = @U;
IF (SELECT Status FROM @rRej) <> 1
BEGIN SET @ErrMsg = N'RejectEvent_Record failed: ' + ISNULL((SELECT Message FROM @rRej), N'?'); THROW 51000, @ErrMsg, 1; END

DELETE FROM @rDown;
INSERT INTO @rDown EXEC Oee.DowntimeEvent_Start @LocationId = @L_FPRPY, @AppUserId = @U;
IF (SELECT Status FROM @rDown) <> 1
BEGIN SET @ErrMsg = N'DowntimeEvent_Start failed: ' + ISNULL((SELECT Message FROM @rDown), N'?'); THROW 51000, @ErrMsg, 1; END
DECLARE @X_DowntimeId BIGINT = (SELECT NewId FROM @rDown);

PRINT N'    cross-cutting ready: pause=' + CAST(@X_PauseId AS NVARCHAR(20)) + N' on ' + @B_MoutMachinedName
    + N', reject 2 pcs on ' + @B_MoutMachinedName + N', downtime=' + CAST(@X_DowntimeId AS NVARCHAR(20)) + N' at MA1-FPRPY.';

-- ============================================================
-- WHAT TO SMOKE
-- ============================================================
PRINT N'';
PRINT N'==================================================================';
PRINT N'  DEMO SEED READY - WHAT TO SMOKE';
PRINT N'==================================================================';
PRINT N'';
PRINT N'1) DIE CAST  /shop-floor/die-cast  (cell DC1-M01, operator DEV)';
PRINT N'     WIP cast LOT ' + @B_CastAtDC1Name + N' (24 pcs) sitting at DC1-M01 -- pick it up, or shoot a new one (tool DEMO-DC-6MA, cavity 1/2).';
PRINT N'';
PRINT N'2) TRIM  /shop-floor/trim  (cell TRIM1, operator DEV)';
PRINT N'     WIP cast LOT ' + @B_CastAtTrimName + N' sitting at TRIM1 -- trim it out to MA1-FPRPY-MIN.';
PRINT N'';
PRINT N'3) MACHINING IN  /shop-floor/machining-in  (line MA1-FPRPY, operator DEV)';
PRINT N'     Unworked arrival ' + @B_MinCastName + N' (Id ' + CAST(@B_MinCast AS NVARCHAR(20)) + N', 24 pcs) waiting at MA1-FPRPY-MIN -- pick it (records the MachiningIn checkpoint; it then drops off the unworked queue).';
PRINT N'';
PRINT N'4) MACHINING OUT (extract-one split)  /shop-floor/machining-out  (line MA1-FPRPY)';
PRINT N'     LOT ' + @B_MoutMachinedName + N' (Id ' + CAST(@B_MoutMachined AS NVARCHAR(20)) + N') at MA1-FPRPY-MOUT: paused + 2-pc reject recorded, 22 pcs remain.';
PRINT N'     Extract a sub-LOT (e.g. 10 of 22) -> destination MA1-FPRPY-AFIN (Id ' + CAST(@L_FPRPY_AFIN AS NVARCHAR(20)) + N') -> parent stays open.';
PRINT N'';
PRINT N'5) ASSEMBLY NON-SERIALIZED  /shop-floor/assembly-nonserialized  (cell MA1-FPRPY-AFIN)';
PRINT N'     Open container ' + CAST(@B_OpenContainer AS NVARCHAR(20)) + N' (12/24 parts, 1 of 2 trays closed) -- complete tray 2 (PieceCount 12) and watch it fill + auto-complete.';
PRINT N'';
PRINT N'6) SHIPPING DOCK  /shop-floor/shipping  (ShippingLabel Id ' + CAST(@A_ShipLabel AS NVARCHAR(20)) + N')';
PRINT N'     Already shipped: 6MA container ' + CAST(@A_Container AS NVARCHAR(20)) + N', AIM ' + ISNULL(@A_AimId, N'?') + N'.';
PRINT N'     RD-BRKT pass-through: LOT ' + @R_ReceivedName + N' still on the dock (SHIPIN); LOT ' + @R_ShippedName + N' already moved to SHIPOUT.';
PRINT N'';
PRINT N'7) SERIALIZED ASSEMBLY  /shop-floor/assembly-serialized  (line MA1-5GOF -- all 5GOF terminals zone here)';
PRINT N'     Container ' + CAST(@G_Container AS NVARCHAR(20)) + N' has 4 serials placed from producing LOT ' + @G_MachinedName + N' (FG-LOT completion deferred, A4).';
PRINT N'';
PRINT N'8) HOLD MANAGEMENT  /shop-floor/hold-management';
PRINT N'     Release hold Id ' + CAST(@G_HoldId AS NVARCHAR(20)) + N' on 5G0 machined LOT ' + @G_MachinedName + N' -- confirm the hold-blocks-production guard clears.';
PRINT N'';
PRINT N'9) PAUSED-LOT INDICATOR / RESUME';
PRINT N'     Resume pause Id ' + CAST(@X_PauseId AS NVARCHAR(20)) + N' on LOT ' + @B_MoutMachinedName + N' (at MA1-FPRPY-MOUT).';
PRINT N'';
PRINT N'10) DOWNTIME / SUPERVISOR  /shop-floor/downtime  (line MA1-FPRPY)';
PRINT N'     Open downtime Id ' + CAST(@X_DowntimeId AS NVARCHAR(20)) + N' -- end it from the Downtime or Supervisor screen.';
PRINT N'';
PRINT N'11) LOT SEARCH / GENEALOGY VIEWER / AUDIT BROWSER';
PRINT N'     Trace the 6MA-A machined LOT ' + CAST(@A_Machined AS NVARCHAR(20)) + N' -> split sublots -> FG LOTs -> shipped container ' + CAST(@A_Container AS NVARCHAR(20)) + N' (proc-built genealogy + audit).';
PRINT N'     (Cast LOT ' + CAST(@A_Cast AS NVARCHAR(20)) + N' is real, audited WIP but not genealogy-linked to the machined LOT -- no proc builds the cast->machined edge post-rework.)';
PRINT N'==================================================================';
GO
