EXEC Workorder.ProductionEvent_Record
    @LotId                = :lotId,
    @OperationTemplateId  = :operationTemplateId,
    @ShotCount            = :shotCount,
    @ScrapCount           = :scrapCount,
    @ScrapSourceId        = :scrapSourceId,
    @WeightValue          = :weightValue,
    @WeightUomId          = :weightUomId,
    @WorkOrderOperationId = :workOrderOperationId,
    @Remarks              = :remarks,
    @FieldValuesJson      = :fieldValuesJson,
    @AppUserId            = :appUserId,
    @TerminalLocationId   = :terminalLocationId
