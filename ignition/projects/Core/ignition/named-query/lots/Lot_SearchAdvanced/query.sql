EXEC Lots.Lot_SearchAdvanced
    @Query             = :query,
    @ItemId            = :itemId,
    @CreatedFromEt     = :createdFromEt,
    @CreatedToEt       = :createdToEt,
    @ToolId            = :toolId,
    @ToolCavityId      = :toolCavityId,
    @LocationId        = :locationId,
    @MachineLocationId = :machineLocationId,
    @ShiftId           = :shiftId,
    @LotStatusId       = :lotStatusId,
    @LotOriginTypeId   = :lotOriginTypeId,
    @LimitRows         = :limitRows
