EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId            = :shiftId,
    @ToolId             = :toolId,
    @LinesJson          = :linesJson,
    @ShotLossJson       = :shotLossJson,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @GrossShots         = :grossShots,
    @CellLocationId     = :cellLocationId
