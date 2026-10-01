EXEC Lots.ShippingLabel_MarkDispatch
    @ShippingLabelId = :shippingLabelId,
    @Success         = :success,
    @ErrorText       = :errorText,
    @ErrorCondition  = :errorCondition,
    @MaxAttempts     = :maxAttempts
