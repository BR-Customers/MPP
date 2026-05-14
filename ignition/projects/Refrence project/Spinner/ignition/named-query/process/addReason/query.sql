--@engineUUID uniqueidentifier,
--    @name nvarchar(max),
--    @lastEdited datetime,
--    @lastEditedBy varchar(100)
EXEC process.addReason	
	@reasonUUID =:reasonUUID,
	@engineUUID =:engineUUID,
	@name =:name,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy