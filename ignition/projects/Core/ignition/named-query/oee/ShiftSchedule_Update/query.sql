EXEC Oee.ShiftSchedule_Update
    @Id                = :id,
    @Name              = :name,
    @Description       = :description,
    @StartTime         = :startTime,
    @EndTime           = :endTime,
    @DaysOfWeekBitmask = :daysOfWeekBitmask,
    @EffectiveFrom     = :effectiveFrom,
    @AppUserId         = :appUserId
