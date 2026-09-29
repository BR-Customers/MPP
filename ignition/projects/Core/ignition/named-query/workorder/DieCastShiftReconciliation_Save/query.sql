EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId            = :shiftId,
    @CellLocationId     = :cellLocationId,
    @ToolId             = :toolId,
    @ReasonId           = :reasonId,
    @Note               = :note,
    @ActualJson         = :actualJson,
    @MovesJson          = :movesJson,
    @LotsJson           = :lotsJson,
    @RejectsJson        = :rejectsJson,
    @LoadedStamp        = :loadedStamp,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @PreviewOnly        = :previewOnly
