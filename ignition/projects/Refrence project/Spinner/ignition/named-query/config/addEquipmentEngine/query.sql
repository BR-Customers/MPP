--@equipmentUUID uniqueidentifier,
--    @engineUUID uniqueidentifier,
--    @active bit,
--    @lastEdited datetime,
--    @lastEditedBy varchar(100)
--equipmentEngineUUID
EXEC config.addEquipmentEngine 
	@equipmentUUID=:equipmentUUID, 
	@engineUUID=:engineUUID, 
	@active=:active, 
	@lastEdited=:lastEdited, 
	@lastEditedBy=:lastEditedBy,
	@equipmentEngineUUID=:equipmentEngineUUID