--	@plantUUID uniqueidentifier,
--    @name nvarchar(max),
--    @active bit,
--    @lastEdited datetime,
--    @lastEditedBy varchar(100)
EXEC config.addEngine	
	@engineUUID=:engineUUID,
	@plantUUID=:plantUUID, 
	@name=:name, 
	@active=:active, 
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@blockConfig=:blockConfig