EXEC Parts.ContainerConfig_Create
    @ItemId            = :itemId,
    @TraysPerContainer = :traysPerContainer,
    @PartsPerTray      = :partsPerTray,
    @IsSerialized      = :isSerialized,
    @DunnageCode       = :dunnageCode,
    @CustomerCode      = :customerCode,
    @ClosureMethod     = :closureMethod,
    @TargetWeight      = :targetWeight,
    @AppUserId         = :appUserId
