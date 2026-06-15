EXEC Audit.ConfigLog_List
    @StartDate         = :startDate,
    @EndDate           = :endDate,
    @LogEntityTypeCode = :logEntityTypeCode,
    @AppUserId         = :appUserId,
    @LogSeverityCode   = :logSeverityCode,
    @DescriptionLike   = :descriptionLike
