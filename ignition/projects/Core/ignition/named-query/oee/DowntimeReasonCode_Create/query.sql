EXEC Oee.DowntimeReasonCode_Create
    @Code                 = :code,
    @Description          = :description,
    @OperationCategoryId  = :operationCategoryId,
    @DowntimeReasonTypeId = :downtimeReasonTypeId,
    @IsExcused            = :isExcused,
    @AppUserId            = :appUserId
