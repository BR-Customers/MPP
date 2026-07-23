EXEC Audit.OperatorChange_Log
    @OldAppUserId       = :oldAppUserId,
    @NewAppUserId       = :newAppUserId,
    @TerminalLocationId = :terminalLocationId,
    @AppUserId          = :appUserId
