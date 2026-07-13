EXEC Workorder.TrimOut_Record
    @ParentLotId               = :parentLotId,
    @OperationTemplateId       = :operationTemplateId,
    @ShotCount                 = :shotCount,
    @ScrapCount                = :scrapCount,
    @DestinationCellLocationId = :destinationCellLocationId,
    @SourceLocationId          = :sourceLocationId,
    @AppUserId                 = :appUserId,
    @TerminalLocationId        = :terminalLocationId
