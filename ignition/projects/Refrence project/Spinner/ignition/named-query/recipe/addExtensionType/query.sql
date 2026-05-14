--	@name nvarchar(max),
--    @programNameFormat nvarchar(max),
--    @extension nvarchar(max)

EXEC recipe.addExtensionType
	@name=:name, 
	@programNameFormat=:programNameFormat, 
	@extension=:extension,
	@active=:active,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@extensionTypeUUID=:extensionTypeUUID