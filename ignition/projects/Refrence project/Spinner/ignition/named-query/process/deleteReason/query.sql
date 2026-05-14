--	@equipmentUUID uniqueidentifier,
--    @name nvarchar(max),
--    @hostname nvarchar(max),
--    @lastActivated datetime
EXEC process.deleteReason
	@UUID=:UUID