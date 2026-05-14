--@operationUUID uniqueidentifier = null,
--	@name nvarchar(max) = null,
--    @routineName nvarchar(max) = null,
--    @operationTypeUUID uniqueidentifier = null,
--    @active bit = null,
--    @lastEdited datetime = null,
--    @lastEditedBy varchar(100) = null
EXEC recipe.addOperation
	@name=:name, 
	@active=:active,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@operationTypeUUID=:operationTypeUUID,
	@operationUUID=:operationUUID,
	@equipmentType=:equipmentType