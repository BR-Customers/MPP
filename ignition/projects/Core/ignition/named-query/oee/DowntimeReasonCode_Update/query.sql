EXEC Oee.DowntimeReasonCode_Update
    @Id                   = :id,
    @Description          = :description,
    @AreaLocationId       = :areaLocationId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @IsExcused            = :isExcused,
    @AppUserId            = :appUserId
