--	  @plantUUID uniqueidentifier,
--    @extensionTypeUUID uniqueidentifier,
--    @name nvarchar(max),
--    @active bit,
--    @lastEdited datetime,
--    @lastEditedBy varchar(100),
--    @HMI nvarchar(max),
--    @fileName varchar(100)
EXEC config.addEquipment	
	@extensionTypeUUID=:extensionTypeUUID, 
	@name=:name, 
	@active=:active, 
	@lastEdited=:lastEdited , 
	@lastEditedBy=:lastEditedBy, 
	@HMI=:HMI, 
	@fileName=:fileName, 
	@plantUUID=:plantUUID,
	@equipmentUUID=:equipmentUUID,
	@hostname=:hostname