--@engineParameterUUID uniqueidentifier = null,
--	@engineOperationUUID uniqueidentifier = null,
--    @parameterUUID uniqueidentifier = null,
--    @extensionTypeUUID uniqueidentifier = null,
--    @macroVariable varchar(100) = null,
--    @macroValue real = null,
--    @validated bit = null
EXEC recipe.addHeadParameter
	@headParameterUUID=:headParameterUUID,
	@parameterListUUID=:parameterListUUID,
	@macroVariable=:macroVariable,
	@macroValue=:macroValue,
	@validated=:validated,
	@lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@name=:name,
	@assignedCylinder=:assignedCylinder