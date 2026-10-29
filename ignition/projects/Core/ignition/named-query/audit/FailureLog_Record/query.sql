EXEC Audit.FailureLog_Record
    @AppUserId           = :appUserId,
    @LogEntityTypeCode   = :logEntityTypeCode,
    @EntityId            = :entityId,
    @LogEventTypeCode    = :logEventTypeCode,
    @FailureReason       = :failureReason,
    @ProcedureName       = :procedureName,
    @AttemptedParameters = :attemptedParameters,
    @LocationId          = :locationId,
    @LotId               = :lotId