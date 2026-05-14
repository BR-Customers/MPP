--	@blockConfigUUID uniqueidentifier = null,
--    @name nvarchar(max) = null,
--    @active bit = null,
--    @lastEdited datetime = null,
--    @lastEditedBy varchar(100) = null,
--	@cylinderCount int =  null,
--	@bankCount int =  null,
--	@assignedNumbers nvarchar(max) = null
EXEC config.addBlockConfig
	@name=:name, 
	@active=:active, 
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@cylinderCount=:cylinderCount,
	@bankCount=:bankCount,
	@assignedNumbers=:assignedNumbers,
	@blockConfigUUID=:blockConfigUUID