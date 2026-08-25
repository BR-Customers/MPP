SET NOCOUNT ON;

-- Cell 162 (MA2-6FBCHOP) had no Parts.ItemLocation rows, and both Lot_Create and
-- Assembly_CompleteTray gate on eligibility. Register the three items first, mirroring
-- the cell-67 pattern: components are consumption points, the finished good is not.

DECLARE @U BIGINT = 2;
DECLARE @Cell BIGINT = 162;

PRINT '--- eligibility: FG item 23 at the cell ---';
EXEC Parts.ItemLocation_Add
    @ItemId = 23, @LocationId = @Cell, @MinQuantity = NULL, @MaxQuantity = NULL,
    @DefaultQuantity = NULL, @IsConsumptionPoint = 0, @AppUserId = @U;

PRINT '--- eligibility: component 21 (consumption point) ---';
EXEC Parts.ItemLocation_Add
    @ItemId = 21, @LocationId = @Cell, @MinQuantity = NULL, @MaxQuantity = NULL,
    @DefaultQuantity = NULL, @IsConsumptionPoint = 1, @AppUserId = @U;

PRINT '--- eligibility: component 22 (consumption point) ---';
EXEC Parts.ItemLocation_Add
    @ItemId = 22, @LocationId = @Cell, @MinQuantity = NULL, @MaxQuantity = NULL,
    @DefaultQuantity = NULL, @IsConsumptionPoint = 1, @AppUserId = @U;

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
