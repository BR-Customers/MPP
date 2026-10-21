EXEC Quality.ControlledRunDeviation_Raise
    @ControlledRunId    = :controlledRunId,
    @Description        = :description,
    @Justification      = :justification,
    @DefectCodeId       = :defectCodeId,
    @AffectedQuantity   = :affectedQuantity,
    @ExternalReference  = :externalReference,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
