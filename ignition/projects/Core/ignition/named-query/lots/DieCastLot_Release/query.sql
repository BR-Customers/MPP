EXEC Lots.DieCastLot_Release
    @LotId              = :lotId,
    @StorageLocationId  = :storageLocationId,
    @FinalPieceDelta    = :finalPieceDelta,
    @CounterReading     = :counterReading,
    @ScrapLinesJson     = :scrapLinesJson,
    @ShiftId            = :shiftId,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
