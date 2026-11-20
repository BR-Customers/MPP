EXEC Parts.PackOut_Save
    @PackOutId = :packOutId,
    @ItemId = :itemId,
    @ClosureMethod = :closureMethod,
    @Name = :name,
    @TraysPerContainer = :traysPerContainer,
    @PartsPerTray = :partsPerTray,
    @IsSerialized = :isSerialized,
    @DunnageCode = :dunnageCode,
    @CustomerCode = :customerCode,
    @TargetWeight = :targetWeight,
    @ToleranceWeight = :toleranceWeight,
    @AppUserId = :appUserId
