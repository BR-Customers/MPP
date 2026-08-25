SET NOCOUNT ON;

-- Stage component stock at cell 67 (MA1-FP6NA) so Workorder.Assembly_CompleteTray
-- can consume BOM 7 for item 20 (12270-6NA -0001).
--   BOM 7 per finished part: item 19 x1 (SubAssembly), item 21 x1, item 22 x2
--   Container = 4 trays x 6 parts = 24 parts  ->  needs 24 / 24 / 48
-- Seeded with a buffer (30 / 30 / 60) so one bad tray does not strand the fill.
--
-- Plain EXEC (no INSERT-EXEC): Lot_Create ROLLBACKs on rejection, which raises
-- Msg 3915 when captured. Run bare so each status row is visible.

PRINT '--- item 19 (SubAssembly 12270-6NA-M) x30 ---';
EXEC Lots.Lot_Create
    @ItemId = 19, @LotOriginTypeId = 1, @CurrentLocationId = 67,
    @PieceCount = 30, @AppUserId = 2;

PRINT '--- item 21 (92900-06014-1B) x30 ---';
EXEC Lots.Lot_Create
    @ItemId = 21, @LotOriginTypeId = 2, @CurrentLocationId = 67,
    @PieceCount = 30, @AppUserId = 2;

PRINT '--- item 22 (94301-08100) x60 ---';
EXEC Lots.Lot_Create
    @ItemId = 22, @LotOriginTypeId = 2, @CurrentLocationId = 67,
    @PieceCount = 60, @AppUserId = 2;
