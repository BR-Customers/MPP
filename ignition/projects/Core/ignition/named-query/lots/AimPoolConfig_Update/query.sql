EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth      = :targetBufferDepth,
    @TopupThreshold         = :topupThreshold,
    @AlarmWarningDepth      = :alarmWarningDepth,
    @AlarmCriticalDepth     = :alarmCriticalDepth,
    @AimBaseUrl             = :aimBaseUrl,
    @AimCompanyCode         = :aimCompanyCode,
    @AimPathToken           = :aimPathToken,
    @PostWarningAgeMinutes  = :postWarningAgeMinutes,
    @PostCriticalAgeMinutes = :postCriticalAgeMinutes,
    @AppUserId              = :appUserId
