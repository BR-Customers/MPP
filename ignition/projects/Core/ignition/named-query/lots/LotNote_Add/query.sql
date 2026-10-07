EXEC Lots.LotNote_Add
    @LotId              = :lotId,
    @NoteText           = :noteText,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @WasElevated        = :wasElevated,
    @ContextJson        = :contextJson
