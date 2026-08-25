SET NOCOUNT ON;

-- Item 19 (SubAssembly 12270-6NA-M) has MaxLotSize 12, so stage it as 3 lots of 12
-- (36 total; the container fill needs 24). FIFO consume walks lots in CreatedAt order,
-- so multiple lots are exactly the realistic shape anyway.

PRINT '--- item 19 lot A x12 ---';
EXEC Lots.Lot_Create
    @ItemId = 19, @LotOriginTypeId = 1, @CurrentLocationId = 67,
    @PieceCount = 12, @AppUserId = 2;

PRINT '--- item 19 lot B x12 ---';
EXEC Lots.Lot_Create
    @ItemId = 19, @LotOriginTypeId = 1, @CurrentLocationId = 67,
    @PieceCount = 12, @AppUserId = 2;

PRINT '--- item 19 lot C x12 ---';
EXEC Lots.Lot_Create
    @ItemId = 19, @LotOriginTypeId = 1, @CurrentLocationId = 67,
    @PieceCount = 12, @AppUserId = 2;
