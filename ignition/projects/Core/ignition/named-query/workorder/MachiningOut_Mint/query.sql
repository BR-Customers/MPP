EXEC Workorder.MachiningOut_Mint
    @SourceLotId         = :sourceLotId,
    @OperationTemplateId = :operationTemplateId,
    @PieceCount          = :pieceCount,
    @ProducedItemId      = :producedItemId,
    @AppUserId           = :appUserId,
    @TerminalLocationId  = :terminalLocationId,
    @AllowPartial        = :allowPartial
