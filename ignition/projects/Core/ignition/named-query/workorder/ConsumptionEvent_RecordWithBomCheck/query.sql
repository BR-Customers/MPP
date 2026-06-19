EXEC Workorder.ConsumptionEvent_RecordWithBomCheck
    @SourceLotId        = :sourceLotId,
    @ProducingLotId     = :producingLotId,
    @CellLocationId     = :cellLocationId,
    @ConsumedPieceCount = :consumedPieceCount,
    @ContainerSerialId  = :containerSerialId,
    @OverrideAppUserId  = :overrideAppUserId,
    @OverrideAuthorized = :overrideAuthorized,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
