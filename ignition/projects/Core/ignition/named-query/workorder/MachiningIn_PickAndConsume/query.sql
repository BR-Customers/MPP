EXEC Workorder.MachiningIn_PickAndConsume
    @SourceLotId         = :sourceLotId,
    @CellLocationId      = :cellLocationId,
    @QueueOverrideReason = :queueOverrideReason,
    @AppUserId           = :appUserId,
    @TerminalLocationId  = :terminalLocationId
