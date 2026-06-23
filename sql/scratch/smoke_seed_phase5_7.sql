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
-- =============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
USE MPP_MES_Dev;
GO

-- Targets (verified against the dev seed):
--   Cells:  MA1-5GOF-MIN=76  MA1-5GOF-MOUT=78  MA1-5GOF-ASER=80
--           MA1-COMPBR-AOUT=47  MA1-6MD-AOUT=52  MA1-5GOR-ASER=73
--   Items:  5G0=1 (ser, cfg1, 4x12)   5G0-C=2 (non-ser, cfg2, 6x24)   6MA-HSG=4 (non-ser, cfg4, 4x25)
--   AIM pool seeded (100 each) for 5G0 / 5G0-C / 6MA-HSG.
-- Mutation procs return different column counts -> one capture table per shape.

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

-- 0.5 Eligibility: Lot_Create checks Parts.v_EffectiveItemLocation. The dev seed has no
--     eligibility for 5G0 at the machining cells, so seed it (idempotent). (Container_Open
--     does NOT check eligibility, so the assembly/sort/ship cells need nothing here.)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=1 AND LocationId=76 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint) VALUES (1, 76, SYSUTCDATETIME(), 0);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=1 AND LocationId=78 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint) VALUES (1, 78, SYSUTCDATETIME(), 0);
GO

DECLARE @U BIGINT = 1;   -- AppUser for attribution
DECLARE @rLot TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rCon TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @tc   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
DECLARE @cmp  TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @hp   TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- =========================================================================
-- 0.6 BOM-driven rename (FDS-05-033): Machining IN pick renames a whole 5G0 LOT into a
--     machined item via the single active published BOM whose only line is 5G0 (QtyPer 1).
--     Without it, Pick rejects "No active BOM renames ...". Create machined item + BOM once.
-- =========================================================================
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-MACH')
BEGIN
    DECLARE @ci TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @ci EXEC Parts.Item_Create @PartNumber=N'5G0-MACH', @ItemTypeId=4, @Description=N'5G0 Machined Front Cover', @UomId=1, @AppUserId=@U;
END
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-MACH');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@MachItem AND LocationId=76 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint) VALUES (@MachItem, 76, SYSUTCDATETIME(), 0);
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId=@MachItem AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@MachItem, @AppUserId=@U;
    DECLARE @BomId BIGINT = (SELECT NewId FROM @bc);
    DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId=@BomId, @ChildItemId=1, @QtyPer=1, @UomId=1, @AppUserId=@U;
    DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@BomId, @AppUserId=@U;
END

-- =========================================================================
-- 1. MACHINING IN queue: 3 whole 5G0 LOTs at MA1-5GOF-MIN (76)
-- =========================================================================
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=1,@LotOriginTypeId=1,@CurrentLocationId=76,@PieceCount=48,@AppUserId=@U,@LotName=N'SMK-MIN-1';
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=1,@LotOriginTypeId=1,@CurrentLocationId=76,@PieceCount=47,@AppUserId=@U,@LotName=N'SMK-MIN-2';
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=1,@LotOriginTypeId=1,@CurrentLocationId=76,@PieceCount=48,@AppUserId=@U,@LotName=N'SMK-MIN-3';
DECLARE @LotMin1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName=N'SMK-MIN-1');
DECLARE @LotMin3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName=N'SMK-MIN-3');

-- 1b. Pre-place a QualityHold on SMK-MIN-3 (queue shows a Hold pill = mockup parity;
--     and Hold Management has an open hold to release).
INSERT INTO @hp EXEC Quality.Hold_Place @LotId=@LotMin3,@HoldTypeCodeId=1,@Reason=N'Smoke: pre-seeded hold',@AppUserId=@U;
DECLARE @HoldId BIGINT = (SELECT NewId FROM @hp);

-- =========================================================================
-- 2. MACHINING OUT active LOT at MA1-5GOF-MOUT (78)
-- =========================================================================
DELETE FROM @rLot; INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId=1,@LotOriginTypeId=1,@CurrentLocationId=78,@PieceCount=48,@AppUserId=@U,@LotName=N'SMK-MOUT-1';

-- =========================================================================
-- 3. ASSEMBLY SERIALIZED open container (5G0, cfg1) at MA1-5GOF-ASER (80)
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=1,@ContainerConfigId=1,@CellLocationId=80,@AppUserId=@U;
DECLARE @AserCon BIGINT = (SELECT NewId FROM @rCon);

-- =========================================================================
-- 4. ASSEMBLY NON-SERIALIZED open container (5G0-C, cfg2) at MA1-COMPBR-AOUT (47)
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=2,@ContainerConfigId=2,@CellLocationId=47,@AppUserId=@U;
DECLARE @AnonCon BIGINT = (SELECT NewId FROM @rCon);

-- =========================================================================
-- 5. SHIPPING: completed 6MA-HSG container (cfg4, 4x25) at MA1-6MD-AOUT (52)
--    Open -> close 4 trays -> Complete (claims AIM + mints ShippingLabel).
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=4,@ContainerConfigId=4,@CellLocationId=52,@AppUserId=@U;
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
-- 6. SORT CAGE: source 5G0 container w/ 2 serials + open 5G0 dest, at MA1-5GOR-ASER (73)
-- =========================================================================
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=1,@ContainerConfigId=1,@CellLocationId=73,@AppUserId=@U;
DECLARE @SrcCon BIGINT = (SELECT NewId FROM @rCon);
DELETE FROM @rCon; INSERT INTO @rCon EXEC Lots.Container_Open @ItemId=1,@ContainerConfigId=1,@CellLocationId=73,@AppUserId=@U;
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
-- WHAT TO SMOKE
-- =========================================================================
SELECT ViewName, [Pick / Enter], Expect, [Id to use] FROM (VALUES
  (1, N'Machining IN',            N'cell  MA1-5GOF-MIN',              N'3 LOTs: SMK-MIN-1, -2 (Good), -3 (Hold)',     CAST(NULL AS BIGINT)),
  (2, N'Machining OUT (Split)',   N'cell  MA1-5GOF-MOUT',             N'active LOT SMK-MOUT-1 (48 pcs)',              NULL),
  (3, N'Assembly Serialized',     N'cell  MA1-5GOF-ASER',             N'open 5G0 container (0 / 48)',                 @AserCon),
  (4, N'Assembly Non-Serialized', N'cell  MA1-COMPBR-AOUT',           N'open 5G0-C container (0 / 144)',              @AnonCon),
  (5, N'Shipping Dock',           N'ShippingLabel Id ->',             N'ships completed 6MA-HSG container',           @ShipLabel),
  (6, N'Sort Cage: serial ->',    N'ContainerSerial Id ->',           N'migrate SMK-SER-1 (or SER-2)',                @CS1),
  (7, N'Sort Cage: dest ->',      N'New Container Id ->',             N'open 5G0 destination container',              @DstCon),
  (8, N'Hold Mgmt: place ->',     N'LOT name SMK-MIN-1  or Ctr Id',   N'place a hold (container Id e.g. ->)',         @AserCon),
  (9, N'Hold Mgmt: release ->',   N'Hold Event Id ->',                N'release the pre-seeded hold on SMK-MIN-3',    @HoldId),
  (10,N'AIM Pool Config / Tile',  N'(no input)',                      N'thresholds 50/30/20/10; pool depth ~100/part',NULL)
) AS g(Seq, ViewName, [Pick / Enter], Expect, [Id to use])
ORDER BY Seq;
GO
