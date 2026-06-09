EXEC Lots.Lot_UpdateStatus
    @LotId              = :lotId,
    @NewLotStatusId     = :newLotStatusId,
    @Reason             = :reason,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @RowVersion         = :rowVersion
