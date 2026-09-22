EXEC Workorder.TrimPartial_Record
    @LotId               = :lotId,
    @OperationTemplateId = :operationTemplateId,
    @ShotCount           = :shotCount,
    @ScrapLinesJson      = :scrapLinesJson,
    @ShiftId             = :shiftId,
    @SourceLocationId    = :sourceLocationId,
    @AppUserId           = :appUserId,
    @TerminalLocationId  = :terminalLocationId
