SET NOCOUNT ON;

-- Fill the container at cell 67 (MA1-FP6NA) for item 20 (12270-6NA -0001).
-- ContainerConfig 5 = 4 trays x 6 parts = 24. Assembly_CompleteTray auto-opens the
-- container on the first tray and reports ContainerFull=1 on the last. It deliberately
-- does NOT complete the container -- that is the step left for the operator (and the
-- step that claims the AIM shipper ID).

PRINT '--- tray 1 of 4 ---';
EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = 20, @PieceCount = 6, @CellLocationId = 67, @ClosureMethod = N'ByVision', @AppUserId = 2;

PRINT '--- tray 2 of 4 ---';
EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = 20, @PieceCount = 6, @CellLocationId = 67, @ClosureMethod = N'ByVision', @AppUserId = 2;

PRINT '--- tray 3 of 4 ---';
EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = 20, @PieceCount = 6, @CellLocationId = 67, @ClosureMethod = N'ByVision', @AppUserId = 2;

PRINT '--- tray 4 of 4 (expect ContainerFull = 1) ---';
EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = 20, @PieceCount = 6, @CellLocationId = 67, @ClosureMethod = N'ByVision', @AppUserId = 2;
