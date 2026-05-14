--@engineOperationUUID uniqueidentifier = null,
--	@engineUUID uniqueidentifier = null,
--    @operationUUID uniqueidentifier = null
EXEC recipe.addEngineOperation
	@engineUUID=:engineUUID,
	@operationUUID=:operationUUID