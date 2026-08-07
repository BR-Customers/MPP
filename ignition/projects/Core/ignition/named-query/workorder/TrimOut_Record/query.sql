EXEC Workorder.TrimOut_Record
    @ParentLotId               = :parentLotId,
    @OperationTemplateId       = :operationTemplateId,
    @ShotCount                 = :shotCount,
    @ScrapLinesJson            = :scrapLinesJson,
    @DestinationCellLocationId = :destinationCellLocationId,
    @SourceLocationId          = :sourceLocationId,
    @AppUserId                 = :appUserId,
    @TerminalLocationId        = :terminalLocationId
