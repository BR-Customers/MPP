EXEC Audit.Audit_LogInterfaceCall
    @SystemName       = :systemName,
    @Direction        = :direction,
    @LogEventTypeCode = :logEventTypeCode,
    @Description      = :description,
    @RequestPayload   = :requestPayload,
    @ResponsePayload  = :responsePayload,
    @ErrorCondition   = :errorCondition,
    @ErrorDescription = :errorDescription,
    @IsHighFidelity   = :isHighFidelity
