-- =============================================================================
-- smoke_seed_phase5_7.sql
-- Persistent DEV smoke data for the Arc 2 Phase 5/6/7 plant-floor views.
-- Re-runnable: cleans its own prior smoke rows (LotName 'SMK-%' + all containers,
-- dev has no real container data) then recreates a realistic mid-flow state using
-- the production procs. Prints a "WHAT TO SMOKE" guide at the end.
--
-- Run:  sqlcmd -S localhost -d MPP_MES_Dev -E -C -I -i sql\scratch\smoke_seed_phase5_7.sql
-- (Plain INSERT/EXEC -- no single-user needed. If the gateway pool causes lock
--  contention, wrap with ALTER LOGIN ignition DISABLE/ENABLE like the test runner.)
--
-- LOCATION RESOLUTION (2026-06-26): the machining/assembly screens are dedicated-flavor
-- views that bind session.custom.cell to the terminal's PARENT ProductionLine
-- (FDS-02-010 line-resolution). So the smoke data is staged at the LINE locations and
-- every location is resolved BY CODE (never a hardcoded Id) so the seed survives any
-- Location.Location auto-increment reorder.
--   Lines:  MA1-5GOF  (machining IN/OUT + assembly serialized -- 5G0 front)
--           MA1-COMPBR (assembly non-serialized -- 6B2 cam holder)
--           MA1-6MD    (shipping -- 6MA-HSG)
--           MA1-5GOR   (sort cage -- 5G0 rear)
--           WHSE       (incoming WIP staging for the Assembly IN scan-in demo)
--   Items:  5G0=1 (ser, cfg1, 4x12)   5G0-C=2 (non-ser, cfg2, 6x24)   6MA-HSG=4 (non-ser, cfg4, 4x25)
--   AIM pool seeded (100 each) for 5G0 / 5G0-C / 6MA-HSG.
-- Mutation procs return different column counts -> one capture table per shape.
-- =============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
USE MPP_MES_Dev;
GO

-- =========================================================================
-- 0. CLEANUP prior smoke (idempotent, FK-safe order)
-- =========================================================================
DELETE FROM Quality.HoldEvent WHERE ContainerId IS NOT NULL;
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE 'SMK-%');
DELETE FROM Lots.ContainerSerialHistory;
DELETE FROM Lots.ShippingLabel;
DELETE FROM Lots.ContainerSerial;
DELETE FROM Lots.ContainerTray;
DELETE FROM Lots.Container;
DELETE FROM Lots.SerializedPart WHERE SerialNumber LIKE 'SMK-%';
DELETE FROM Lots.LotLabel          WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE 'SMK-%');
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE 'SMK-%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE 'SMK-%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE 'SMK-%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE 'SMK-%');
DELETE FROM Lots.Lot               WHERE LotName LIKE 'SMK-%';
UPDATE Lots.AimShipperIdPool SET ConsumedAt = NULL, ConsumedByContainerId = NULL, ConsumedByUserId = NULL
    WHERE ConsumedByContainerId IS NOT NULL;
GO

DECLARE @U BIGINT = 1;   -- AppUser for attribution

-- ---- Resolve every location BY CODE (line-resolution context) ----
DECLARE @L_5GOF   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @L_COMPBR BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @L_6MD    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD');
DECLARE @L_5GOR   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR');
DECLARE @L_WHSE   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');

DECLARE @rLot TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rCon TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @tc   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
DECLARE @cmp  TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @hp   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- =========================================================================
-- 0.6 BOM-driven rename (FDS-05-033): Machining IN pick renames a whole 5G0-C cast LOT into
--     the machined item via the single active published BOM whose only line is 5G0-C (QtyPer 1).
--     Without it, Pick rejects "No active BOM renames ...". Create machined item + BOM once.
-- =========================================================================
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-MACH')
BEGIN
    DECLARE @ci TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @ci EXEC Parts.Item_Create @PartNumber=N'5G0-MACH', @ItemTypeId=3, @Description=N'5G0 Machined Front Cover', @UomId=1, @AppUserId=@U;  -- normally created by master seed 020 (this guarded block is the fallback)
END
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-MACH');

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId=@MachItem AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@MachItem, @AppUserId=@U;
    DECLARE @BomId BIGINT = (SELECT NewId FROM @bc);
    DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId=@BomId, @ChildItemId=2, @QtyPer=1, @UomId=1, @AppUserId=@U;
    DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@BomId, @AppUserId=@U;
END

-- 0.5 Eligibility (Lot_Create checks Parts.v_EffectiveItemLocation): 5G0-C cast + 5G0-MACH
--     eligible at the 5G0 front line. (Container_Open does NOT check eligibility.)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=2          AND LocationId=@L_5GOF AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint) VALUES (2, @L_5GOF, SYSUTCDATETIME(), 0);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@MachItem AND LocationId=@L_5GOF AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint) VALUES (@MachItem, @L_5GOF, SYSUTCDATETIME(), 0);

-- =========================================================================
-- 0.8 6B2 Cam Holder NON-SERIALIZED assembly chain (FDS-06-013): cast -> machine -> assemble.
--     Rename BOM 6B2-MACH <- 6B2-C; assembly BOM 6B2 <- 6B2-MACH x1 + 6B2-PIN x2 (consumed per tray).
--     The 6B2 container (line MA1-COMPBR) is the operator-testable non-ser consumption demo.
-- =========================================================================
DECLARE @ci2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bc2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bl2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp2 TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @ccr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'6B2-C')    BEGIN DELETE FROM @ci2; INSERT INTO @ci2 EXEC Parts.Item_Create @PartNumber=N'6B2-C',    @ItemTypeId=2, @Description=N'6B2 Cam Holder Casting', @UomId=1, @AppUserId=@U; END
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'6B2-MACH') BEGIN DELETE FROM @ci2; INSERT INTO @ci2 EXEC Parts.Item_Create @PartNumber=N'6B2-MACH', @ItemTypeId=3, @Description=N'6B2 Machined Cam Holder', @UomId=1, @AppUserId=@U; END
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'6B2-PIN')  BEGIN DELETE FROM @ci2; INSERT INTO @ci2 EXEC Parts.Item_Create @PartNumber=N'6B2-PIN',  @ItemTypeId=2, @Description=N'6B2 Mounting Pin', @UomId=1, @AppUserId=@U; END
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'6B2')      BEGIN DELETE FROM @ci2; INSERT INTO @ci2 EXEC Parts.Item_Create @PartNumber=N'6B2',      @ItemTypeId=4, @Description=N'6B2 Cam Holder Assembly', @UomId=1, @AppUserId=@U; END
DECLARE @B2C BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'6B2-C');
DECLARE @B2M BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'6B2-MACH');
DECLARE @B2P BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'6B2-PIN');
DECLARE @B2  BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'6B2');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId=@B2M AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc2; INSERT INTO @bc2 EXEC Parts.Bom_Create @ParentItemId=@B2M, @AppUserId=@U;
    DECLARE @B2MBom BIGINT=(SELECT NewId FROM @bc2);
    DELETE FROM @bl2; INSERT INTO @bl2 EXEC Parts.BomLine_Add @BomId=@B2MBom, @ChildItemId=@B2C, @QtyPer=1, @UomId=1, @AppUserId=@U;
    DELETE FROM @bp2; INSERT INTO @bp2 EXEC Parts.Bom_Publish @Id=@B2MBom, @AppUserId=@U;
END
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId=@B2 AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc2; INSERT INTO @bc2 EXEC Parts.Bom_Create @ParentItemId=@B2, @AppUserId=@U;
    DECLARE @B2Bom BIGINT=(SELECT NewId FROM @bc2);
    DELETE FROM @bl2; INSERT INTO @bl2 EXEC Parts.BomLine_Add @BomId=@B2Bom, @ChildItemId=@B2M, @QtyPer=1, @UomId=1, @AppUserId=@U;
    DELETE FROM @bl2; INSERT INTO @bl2 EXEC Parts.BomLine_Add @BomId=@B2Bom, @ChildItemId=@B2P, @QtyPer=2, @UomId=1, @AppUserId=@U;
    DELETE FROM @bp2; INSERT INTO @bp2 EXEC Parts.Bom_Publish @Id=@B2Bom, @AppUserId=@U;
END
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId=@B2 AND DeprecatedAt IS NULL)
BEGIN DELETE FROM @ccr; INSERT INTO @ccr EXEC Parts.ContainerConfig_Create @ItemId=@B2, @TraysPerContainer=4, @PartsPerTray=24, @IsSerialized=0, @ClosureMethod=N'ByCount', @AppUserId=@U; END
DECLARE @B2Cfg BIGINT=(SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId=@B2 AND DeprecatedAt IS NULL);
-- eligibility: components staged/consumed at the assembly line MA1-COMPBR; 6B2 (the assembly)
-- is produced there (IsConsumptionPoint=0 so Assembly_ScanIn validates the BOM-component scan).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@B2M AND LocationId=@L_COMPBR AND DeprecatedAt IS NULL) INSERT INTO Parts.ItemLocation (ItemId,LocationId,CreatedAt,IsConsumptionPoint) VALUES (@B2M,@L_COMPBR,SYSUTCDATETIME(),0);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@B2P AND LocationId=@L_COMPBR AND DeprecatedAt IS NULL) INSERT INTO Parts.ItemLocation (ItemId,LocationId,CreatedAt,IsConsumptionPoint) VALUES (@B2P,@L_COMPBR,SYSUTCDATETIME(),0);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@B2  AND LocationId=@L_COMPBR AND DeprecatedAt IS NULL) INSERT INTO Parts.ItemLocation (ItemId,LocationId,CreatedAt,IsConsumptionPoint) VALUES (@B2,@L_COMPBR,SYSUTCDATETIME(),0);
-- stage the BOM components at the assembly line (4 trays x 24: need 96 6B2-MACH + 192 6B2-PIN)
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=@B2M,@LotOriginTypeId=1,@CurrentLocationId=@L_COMPBR,@PieceCount=96, @AppUserId=@U,@LotName=N'SMK-6B2M-47';
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=@B2P,@LotOriginTypeId=1,@CurrentLocationId=@L_COMPBR,@PieceCount=192,@AppUserId=@U,@LotName=N'SMK-6B2P-47';
-- a machined 6B2 LOT staged in the warehouse (incoming WIP) for the Assembly IN scan-in demo:
-- the operator scans it to move it INTO the MA1-COMPBR queue.
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=@B2M,@LotOriginTypeId=1,@CurrentLocationId=@L_WHSE,@PieceCount=24, @AppUserId=@U,@LotName=N'SMK-6B2M-SCAN';

-- =========================================================================
-- 1. MACHINING IN queue: 3 whole 5G0-C cast LOTs at the 5G0 front line -> renamed to 5G0-MACH on pick
-- =========================================================================
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=2,@LotOriginTypeId=1,@CurrentLocationId=@L_5GOF,@PieceCount=48,@AppUserId=@U,@LotName=N'SMK-MIN-1';
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=2,@LotOriginTypeId=1,@CurrentLocationId=@L_5GOF,@PieceCount=47,@AppUserId=@U,@LotName=N'SMK-MIN-2';
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=2,@LotOriginTypeId=1,@CurrentLocationId=@L_5GOF,@PieceCount=48,@AppUserId=@U,@LotName=N'SMK-MIN-3';
DECLARE @LotMin1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName=N'SMK-MIN-1');
DECLARE @LotMin3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName=N'SMK-MIN-3');

-- 1b. Pre-place a QualityHold on SMK-MIN-3 (queue shows a Hold pill = mockup parity;
--     and Hold Management has an open hold to release).
INSERT INTO @hp EXEC Quality.Hold_Place @LotId=@LotMin3,@HoldTypeCodeId=1,@Reason=N'Smoke: pre-seeded hold',@AppUserId=@U;
DECLARE @HoldId BIGINT = (SELECT NewId FROM @hp);

-- =========================================================================
-- 2. MACHINING OUT active LOT at the 5G0 front line
-- =========================================================================
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=@MachItem,@LotOriginTypeId=1,@CurrentLocationId=@L_5GOF,@PieceCount=48,@AppUserId=@U,@LotName=N'SMK-MOUT-1';

-- =========================================================================
-- 3. ASSEMBLY SERIALIZED open container (5G0, cfg1) at the 5G0 front line
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=1,@ContainerConfigId=1,@CellLocationId=@L_5GOF,@AppUserId=@U;
DECLARE @AserCon BIGINT = (SELECT NewId FROM @rCon);
DECLARE @si INT = 1;
WHILE @si <= 4 BEGIN DELETE FROM @tc; INSERT INTO @tc EXEC Lots.ContainerTray_Close @ContainerId=@AserCon,@TrayPosition=@si,@PartsCount=12,@ClosureMethod=N'ByVision',@AppUserId=@U; SET @si += 1; END

-- =========================================================================
-- 4. ASSEMBLY NON-SERIALIZED open container (6B2, non-ser 4x24) at MA1-COMPBR
--    Components 6B2-MACH + 6B2-PIN staged at the line (0.8); each tray close consumes them.
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=@B2,@ContainerConfigId=@B2Cfg,@CellLocationId=@L_COMPBR,@AppUserId=@U;
DECLARE @AnonCon BIGINT = (SELECT NewId FROM @rCon);

-- =========================================================================
-- 5. SHIPPING: completed 6MA-HSG container (cfg4, 4x25) at MA1-6MD
--    Open -> close 4 trays -> Complete (claims AIM + mints ShippingLabel).
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=4,@ContainerConfigId=4,@CellLocationId=@L_6MD,@AppUserId=@U;
DECLARE @ShipCon BIGINT = (SELECT NewId FROM @rCon);
DECLARE @i INT = 1;
WHILE @i <= 4
BEGIN
    DELETE FROM @tc;
    INSERT INTO @tc EXEC Lots.ContainerTray_Close @ContainerId=@ShipCon,@TrayPosition=@i,@PartsCount=25,@ClosureMethod=N'ByCount',@AppUserId=@U;
    SET @i += 1;
END
INSERT INTO @cmp EXEC Lots.Container_Complete @ContainerId=@ShipCon,@OperatorConfirmed=1,@AppUserId=@U;
DECLARE @ShipLabel BIGINT = (SELECT ShippingLabelId FROM @cmp);

-- =========================================================================
-- 6. SORT CAGE: source 5G0 container w/ 2 serials + open 5G0 dest, at MA1-5GOR
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=1,@ContainerConfigId=1,@CellLocationId=@L_5GOR,@AppUserId=@U;
DECLARE @SrcCon BIGINT = (SELECT NewId FROM @rCon);
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=1,@ContainerConfigId=1,@CellLocationId=@L_5GOR,@AppUserId=@U;
DECLARE @DstCon BIGINT = (SELECT NewId FROM @rCon);

DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId)
VALUES (N'SMK-SER-1', 1, @LotMin1, @now, @U), (N'SMK-SER-2', 1, @LotMin1, @now, @U);
DECLARE @SP1 BIGINT = (SELECT Id FROM Lots.SerializedPart WHERE SerialNumber=N'SMK-SER-1');
DECLARE @SP2 BIGINT = (SELECT Id FROM Lots.SerializedPart WHERE SerialNumber=N'SMK-SER-2');
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed, CreatedAt)
VALUES (@SrcCon, NULL, @SP1, 1, 0, @now), (@SrcCon, NULL, @SP2, 2, 0, @now);
DECLARE @CS1 BIGINT = (SELECT Id FROM Lots.ContainerSerial WHERE SerializedPartId=@SP1);
DECLARE @CS2 BIGINT = (SELECT Id FROM Lots.ContainerSerial WHERE SerializedPartId=@SP2);

-- =========================================================================
-- WHAT TO SMOKE   (terminals route via DefaultScreen; pick the terminal in the
-- selector, or navigate directly. All machining/assembly context = the LINE.)
-- =========================================================================
SELECT ViewName, [Pick / Enter], Expect, [Id to use] FROM (VALUES
  (1, N'Machining IN',            N'terminal MA1-5GOF-MIN  (line MA1-5GOF)',  N'3 LOTs: SMK-MIN-1, -2 (Good), -3 (Hold)',     CAST(NULL AS BIGINT)),
  (2, N'Machining OUT (Split)',   N'terminal MA1-5GOF-MOUT (line MA1-5GOF)',  N'active LOT SMK-MOUT-1 (48 pcs)',              NULL),
  (3, N'Assembly Serialized',     N'terminal MA1-5GOF-ASER (line MA1-5GOF)',  N'open 5G0 container (0 / 48)',                 @AserCon),
  (4, N'Assembly Non-Serialized', N'terminal MA1-COMPBR-AOUT (line MA1-COMPBR)', N'open 6B2 container (0 / 96), consumes 6B2-MACH + 6B2-PIN', @AnonCon),
  (11,N'Assembly IN',             N'scan LTT SMK-6B2M-SCAN (line MA1-COMPBR)', N'moves the 6B2-MACH LOT (from WHSE) into the line queue', CAST(NULL AS BIGINT)),
  (5, N'Shipping Dock',           N'ShippingLabel Id ->',                     N'ships completed 6MA-HSG container',           @ShipLabel),
  (6, N'Sort Cage: serial ->',    N'ContainerSerial Id ->',                   N'migrate SMK-SER-1 (or SER-2)',                @CS1),
  (7, N'Sort Cage: dest ->',      N'New Container Id ->',                     N'open 5G0 destination container',              @DstCon),
  (8, N'Hold Mgmt: place ->',     N'LOT name SMK-MIN-1  or Ctr Id',          N'place a hold (container Id e.g. ->)',         @AserCon),
  (9, N'Hold Mgmt: release ->',   N'Hold Event Id ->',                        N'release the pre-seeded hold on SMK-MIN-3',    @HoldId),
  (10,N'AIM Pool Config / Tile',  N'(no input)',                             N'thresholds 50/30/20/10; pool depth ~100/part',NULL)
) AS g(Seq, ViewName, [Pick / Enter], Expect, [Id to use])
ORDER BY Seq;
GO
