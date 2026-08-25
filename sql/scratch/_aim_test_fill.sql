SET NOCOUNT ON;

-- Stage stock at cell 162 (MA2-6FBCHOP, the 6FB cell) and fill the container for
-- item 23 (11200-6FB -A000 -> AIM '112006FB A000').
--   BOM per part: item 21 x1, item 22 x2.  Container = 2 trays x 3 = 6 parts.
--   So the fill needs 6 of item 21 and 12 of item 22; staged with buffer.

DECLARE @U BIGINT = 2;
DECLARE @Cell BIGINT = 162;

PRINT '--- stock: 92900-06014-1B x12 ---';
EXEC Lots.Lot_Create
    @ItemId = 21, @LotOriginTypeId = 2, @CurrentLocationId = @Cell,
    @PieceCount = 12, @AppUserId = @U;

PRINT '--- stock: 94301-08100 x24 ---';
EXEC Lots.Lot_Create
    @ItemId = 22, @LotOriginTypeId = 2, @CurrentLocationId = @Cell,
    @PieceCount = 24, @AppUserId = @U;

PRINT '--- tray 1 of 2 ---';
EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = 23, @PieceCount = 3, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = @U;

PRINT '--- tray 2 of 2 (expect Container is full) ---';
EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = 23, @PieceCount = 3, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = @U;
