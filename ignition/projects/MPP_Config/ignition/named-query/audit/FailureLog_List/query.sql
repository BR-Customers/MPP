EXEC Audit.FailureLog_List
    @StartDate         = :startDate,
    @EndDate           = :endDate,
    @LogEntityTypeCode = :logEntityTypeCode,
    @AppUserId         = :appUserId,
    @ProcedureName     = :procedureName,
    @FailureReasonLike = :failureReasonLike
