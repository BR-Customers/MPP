EXEC Parts.ContainerConfig_Create
    @ItemId            = :itemId,
    @TraysPerContainer = :traysPerContainer,
    @PartsPerTray      = :partsPerTray,
    @IsSerialized      = :isSerialized,
    @DunnageCode       = :dunnageCode,
    @CustomerCode      = :customerCode,
    @ClosureMethod     = :closureMethod,
    @TargetWeight      = :targetWeight,
    @ToleranceWeight   = :toleranceWeight,
    @AppUserId         = :appUserId
