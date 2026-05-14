--@engineParameterUUID uniqueidentifier = null,
--	@engineOperationUUID uniqueidentifier = null,
--    @parameterUUID uniqueidentifier = null,
--    @extensionTypeUUID uniqueidentifier = null,
--    @macroVariable varchar(100) = null,
--    @macroValue real = null,
--    @validated bit = null
EXEC recipe.addEngineParameter
	@engineParameterUUID=:engineParameterUUID,
	@parameterListUUID=:parameterListUUID,
	@macroVariable=:macroVariable,
	@macroValue=:macroValue,
	@validated=:validated,
	@active=:active,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@name=:name,
	@assignedCylinder=:assignedCylinder