EXEC Workorder.RejectEvent_Record
    @LotId              = :lotId,
    @DefectCodeId       = :defectCodeId,
    @Quantity           = :quantity,
    @ProductionEventId  = :productionEventId,
    @ChargeToArea       = :chargeToArea,
    @Remarks            = :remarks,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
