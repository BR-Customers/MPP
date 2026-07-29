EXEC Oee.ShiftSchedule_Create
    @Name              = :name,
    @Description       = :description,
    @StartTime         = :startTime,
    @EndTime           = :endTime,
    @DaysOfWeekBitmask = :daysOfWeekBitmask,
    @EffectiveFrom     = :effectiveFrom,
    @AppUserId         = :appUserId
