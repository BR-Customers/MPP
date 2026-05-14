--@plantUUID uniqueidentifier = null,
--	@name nvarchar(max) = null,
--    @active bit = null,
--    @lastEdited datetime = null,
--    @lastEditedBy varchar(100) = null,
--    @location nvarchar(100) = null
EXEC config.addPlant
	@plantUUID=:plantUUID,
	@name=:name,
	@active=:active,
	@location=:location,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy