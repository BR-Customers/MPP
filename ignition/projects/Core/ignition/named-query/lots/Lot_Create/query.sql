EXEC Lots.Lot_Create
    @ItemId             = :itemId,
    @LotOriginTypeId    = :lotOriginTypeId,
    @CurrentLocationId  = :currentLocationId,
    @PieceCount         = :pieceCount,
    @Weight             = :weight,
    @WeightUomId        = :weightUomId,
    @ToolId             = :toolId,
    @ToolCavityId       = :toolCavityId,
    @VendorLotNumber    = :vendorLotNumber,
    @MinSerialNumber    = :minSerialNumber,
    @MaxSerialNumber    = :maxSerialNumber,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
