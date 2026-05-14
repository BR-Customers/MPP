--	@equipmentUUID uniqueidentifier,
--    @name nvarchar(max),
--    @hostname nvarchar(max),
--    @lastActivated datetime
EXEC config.addAsset	
	@assetUUID=:assetUUID,
	@name=:name, 
	@hostname=:hostname, 
	@lastActivated=:lastActivated, 
	@equipmentUUID=:equipmentUUID,
	@active=:active,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy