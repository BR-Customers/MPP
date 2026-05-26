EXEC Parts.ContainerConfig_Update
    @Id                = :id,
    @TraysPerContainer = :traysPerContainer,
    @PartsPerTray      = :partsPerTray,
    @IsSerialized      = :isSerialized,
    @DunnageCode       = :dunnageCode,
    @CustomerCode      = :customerCode,
    @ClosureMethod     = :closureMethod,
    @TargetWeight      = :targetWeight,
    @AppUserId         = :appUserId
