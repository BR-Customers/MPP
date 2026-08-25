SET NOCOUNT ON;

-- Stage 4 non-serialized Assembly lines for ByVision / ByWeight closure practice
-- with the PLC device simulator. Plain EXEC (no INSERT-EXEC) throughout per the
-- established convention -- Lot_Create/ContainerConfig_Create ROLLBACK on
-- rejection, which raises Msg 3915 when captured, so each status row must be
-- visible bare.
--
-- Survey (Dev, 2026-08-20): of every non-serialized Assembly-Out terminal with a
-- ByVision or ByWeight PLC device bound, cross-checked against the eligible
-- finished good's ContainerConfig for that SAME closure method, only ByVision
-- triples existed end-to-end. Every ByWeight-capable terminal's eligible item(s)
-- had a ByVision ContainerConfig only -- a real commissioning gap (companion to
-- the already-flagged "9 of 18 Assembly-Out terminals have zero PLC devices"
-- finding). Rather than fabricate new terminal/PLC bindings, this fills the
-- narrower gap: 2 ByWeight ContainerConfig rows for finished goods already
-- eligible at terminals that already carry a real ByWeight PLC device.
--
--   Line                Terminal            Cell(zone)   Item                          Method(s)
--   ----                --------            ----------   ----                          ---------
--   MA2-6FBCHOP-AOUT     (terminal 165)      162          129 12235-6FB-A000 (6FB Oil Pass)   ByVision (existing)
--   MA2-6MAOP-AOUT       (terminal 142)      139          119 1120A-69F-A000 (69F Oil Pan)     ByVision (existing)
--   MA2-RPY6B2-AOUT      (terminal 96)       89           101 12270-6B2-A000 (6B2 Fuel Pump)   ByVision (existing) + ByWeight (NEW config)
--   MA2-5PA-AOUT         (terminal 268)      132          95  12270-5PA-A000 (5PA Fuel Pump)   ByWeight (NEW config)
--
-- RPY6B2's terminal already carries BOTH PLC device types, so once the ByWeight
-- config is added it is a single line to flip closure method on and test both
-- paths without moving cells.

-- ============================================================
-- A. Fill the ByWeight ContainerConfig gap (2 rows)
-- ============================================================

PRINT '--- ContainerConfig: item 101 (6B2 Fuel Pump) ByWeight, mirrors its ByVision PartsPerTray/TraysPerContainer ---';
EXEC Parts.ContainerConfig_Create
    @ItemId = 101, @TraysPerContainer = 16, @PartsPerTray = 10,
    @ClosureMethod = N'ByWeight', @AppUserId = 2;

PRINT '--- ContainerConfig: item 95 (5PA Fuel Pump) ByWeight, mirrors its ByVision PartsPerTray/TraysPerContainer ---';
EXEC Parts.ContainerConfig_Create
    @ItemId = 95, @TraysPerContainer = 12, @PartsPerTray = 12,
    @ClosureMethod = N'ByWeight', @AppUserId = 2;

-- ============================================================
-- B. Component stock at cell 162 (MA2-6FBCHOP) for item 129, PartsPerTray=14
--    BOM: item 130 x1, item 22 x2 -- staged for ~3 tray closes + buffer
-- ============================================================

PRINT '--- cell 162: item 130 (6FB Oil Pass Raw, machined) x50 ---';
EXEC Lots.Lot_Create
    @ItemId = 130, @LotOriginTypeId = 1, @CurrentLocationId = 162,
    @PieceCount = 50, @AppUserId = 2;

PRINT '--- cell 162: item 22 (8x10 Dowel Pin) x100 ---';
EXEC Lots.Lot_Create
    @ItemId = 22, @LotOriginTypeId = 2, @CurrentLocationId = 162,
    @PieceCount = 100, @AppUserId = 2;

-- ============================================================
-- C. Component stock at cell 139 (MA2-6MAOP) for item 119, PartsPerTray=60,
--    TraysPerContainer=1 (one tray closes the whole container).
--    BOM: 7 lines, all QtyPer=1 -- staged for 2 full container closes.
-- ============================================================

PRINT '--- cell 139: item 22 (8x10 Dowel Pin) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 22, @LotOriginTypeId = 2, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

PRINT '--- cell 139: item 115 (M22 Stud / Oil Filter Holder) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 115, @LotOriginTypeId = 2, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

PRINT '--- cell 139: item 116 (14mm Drain Plug Washer) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 116, @LotOriginTypeId = 2, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

PRINT '--- cell 139: item 120 (6MA Oil Pan Raw, machined) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 120, @LotOriginTypeId = 1, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

PRINT '--- cell 139: item 121 (18x13 Dowel Pin) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 121, @LotOriginTypeId = 2, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

PRINT '--- cell 139: item 122 (Drain Plug Bolt) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 122, @LotOriginTypeId = 2, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

PRINT '--- cell 139: item 123 (23x2.3 O-ring) x120 ---';
EXEC Lots.Lot_Create
    @ItemId = 123, @LotOriginTypeId = 2, @CurrentLocationId = 139,
    @PieceCount = 120, @AppUserId = 2;

-- ============================================================
-- D. Component stock at cell 89 (MA2-RPY6B2) for item 101, PartsPerTray=10
--    (same stock serves BOTH ByVision and the new ByWeight config -- switch
--    the terminal's closure method between practice runs).
--    BOM: item 100 x2, item 103 x2, item 104 x1, item 176 x1 -- ~3 closes + buffer
-- ============================================================

PRINT '--- cell 89: item 100 (10x12 Dowel Pin) x75 ---';
EXEC Lots.Lot_Create
    @ItemId = 100, @LotOriginTypeId = 2, @CurrentLocationId = 89,
    @PieceCount = 75, @AppUserId = 2;

PRINT '--- cell 89: item 103 (6x12 Stud Bolt) x75 ---';
EXEC Lots.Lot_Create
    @ItemId = 103, @LotOriginTypeId = 2, @CurrentLocationId = 89,
    @PieceCount = 75, @AppUserId = 2;

PRINT '--- cell 89: item 104 (6x50 Stud Bolt) x40 ---';
EXEC Lots.Lot_Create
    @ItemId = 104, @LotOriginTypeId = 2, @CurrentLocationId = 89,
    @PieceCount = 40, @AppUserId = 2;

PRINT '--- cell 89: item 176 (6B2 Fuel Pump Raw, machined) x40 ---';
EXEC Lots.Lot_Create
    @ItemId = 176, @LotOriginTypeId = 1, @CurrentLocationId = 89,
    @PieceCount = 40, @AppUserId = 2;

-- ============================================================
-- E. Component stock at cell 132 (MA2-5PA) for item 95, PartsPerTray=12
--    BOM: item 21 x1, item 22 x1, item 175 x1 -- ~3 closes + buffer
-- ============================================================

PRINT '--- cell 132: item 21 (6x14 Stud Bolt) x45 ---';
EXEC Lots.Lot_Create
    @ItemId = 21, @LotOriginTypeId = 2, @CurrentLocationId = 132,
    @PieceCount = 45, @AppUserId = 2;

PRINT '--- cell 132: item 22 (8x10 Dowel Pin) x45 ---';
EXEC Lots.Lot_Create
    @ItemId = 22, @LotOriginTypeId = 2, @CurrentLocationId = 132,
    @PieceCount = 45, @AppUserId = 2;

PRINT '--- cell 132: item 175 (5PA Fuel Pump Raw, machined) x45 ---';
EXEC Lots.Lot_Create
    @ItemId = 175, @LotOriginTypeId = 1, @CurrentLocationId = 132,
    @PieceCount = 45, @AppUserId = 2;
