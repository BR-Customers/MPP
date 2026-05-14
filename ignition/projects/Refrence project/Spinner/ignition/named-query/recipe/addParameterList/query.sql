--@parameterListUUID uniqueidentifier = null,
--	@name nvarchar(max) = null,
--	@active bit = null,
--	@lastEdited datetime = null,
--    @lastEditedBy varchar(100) = null,
--	@validated bit = null,
--	@engineOperationUUID uniqueidentifier = null,
--	@extensionTypeUUID uniqueidentifier = null
EXEC recipe.addParameterList
	@parameterListUUID=:parameterListUUID,
	@name=:name,
	@active=:active,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@validated=:validated,
	@engineOperationUUID=:engineOperationUUID,
	@extensionTypeUUID=:extensionTypeUUID