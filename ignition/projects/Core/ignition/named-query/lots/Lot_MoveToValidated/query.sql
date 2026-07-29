EXEC Lots.Lot_MoveToValidated
    @LotId              = :lotId,
    @ToLocationId       = :toLocationId,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @OperationTypeCode  = :operationTypeCode,
    @OverrideAppUserId  = :overrideAppUserId
