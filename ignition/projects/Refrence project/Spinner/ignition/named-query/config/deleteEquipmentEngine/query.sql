--	@equipmentUUID uniqueidentifier,
--    @name nvarchar(max),
--    @hostname nvarchar(max),
--    @lastActivated datetime
EXEC config.deleteEquipmentEngine
	@UUID=:UUID