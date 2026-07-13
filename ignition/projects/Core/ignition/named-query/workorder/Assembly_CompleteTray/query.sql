EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = :finishedGoodItemId,
    @PieceCount         = :pieceCount,
    @CellLocationId     = :cellLocationId,
    @ClosureMethod      = :closureMethod,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
