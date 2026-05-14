--@operationTypeUUID uniqueidentifier = null,
--	@name nvarchar(max) = null,
--    @active bit = null,
--    @lastEdited datetime = null,
--    @lastEditedBy varchar(100) = null,
--    @hmiView nvarchar(max) = null,
--	@notes nvarchar(max) = null

EXEC recipe.addOperationType
	@name=:name, 
	@hmiView=:hmiView, 
	@notes=:notes,
	@active=:active,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@operationTypeUUID=:operationTypeUUID