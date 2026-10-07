EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId             = :itemId,
    @LocationId         = :locationId,
    @DefectCodeId       = :defectCodeId,
    @Quantity           = :quantity,
    @Remarks            = :remarks,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @OperationTypeCode  = :operationTypeCode
