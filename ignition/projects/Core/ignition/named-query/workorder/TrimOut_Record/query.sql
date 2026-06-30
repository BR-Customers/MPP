EXEC Workorder.TrimOut_Record
    @ParentLotId               = :parentLotId,
    @OperationTemplateId       = :operationTemplateId,
    @ShotCount                 = :shotCount,
    @ScrapCount                = :scrapCount,
    @DestinationCellLocationId = :destinationCellLocationId,
    @AppUserId                 = :appUserId,
    @TerminalLocationId        = :terminalLocationId
