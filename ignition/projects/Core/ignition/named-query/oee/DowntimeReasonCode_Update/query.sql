EXEC Oee.DowntimeReasonCode_Update
    @Id                   = :id,
    @Description          = :description,
    @OperationCategoryId  = :operationCategoryId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @IsExcused            = :isExcused,
    @AppUserId            = :appUserId
