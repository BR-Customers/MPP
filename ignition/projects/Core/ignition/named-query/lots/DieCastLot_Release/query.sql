EXEC Lots.DieCastLot_Release
    @LotId              = :lotId,
    @StorageLocationId  = :storageLocationId,
    @FinalPieceDelta    = :finalPieceDelta,
    @ScrapLinesJson     = :scrapLinesJson,
    @ShiftId            = :shiftId,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
