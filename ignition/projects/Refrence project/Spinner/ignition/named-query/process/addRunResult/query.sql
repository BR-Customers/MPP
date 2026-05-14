--    @runResultUUID UNIQUEIDENTIFIER = NULL,
--    @status NVARCHAR(MAX) = NULL,
--    @reasonUUID UNIQUEIDENTIFIER = NULL,
--    @lastEdited DATETIME = NULL,
--    @lastEditedBy VARCHAR(100) = NULL
EXEC process.addRunResult	
	@runResultUUID =:runResultUUID,
	@status =:status,
	@reasonUUID =:reasonUUID,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy