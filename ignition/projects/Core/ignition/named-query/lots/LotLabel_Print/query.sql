EXEC Lots.LotLabel_Print
    @LotId              = :lotId,
    @LabelTypeCodeId    = :labelTypeCodeId,
    @PrintReasonCodeId  = :printReasonCodeId,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @PrinterName        = :printerName
