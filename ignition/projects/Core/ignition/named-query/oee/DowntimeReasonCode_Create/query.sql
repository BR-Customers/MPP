EXEC Oee.DowntimeReasonCode_Create
    @Code                 = :code,
    @Description          = :description,
    @AreaLocationId       = :areaLocationId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @IsExcused            = :isExcused,
    @AppUserId            = :appUserId
