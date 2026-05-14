--@parameterDefaultUUID uniqueidentifier,
--	@parameterUUID uniqueidentifier,
--    @extensionTypeUUID uniqueidentifier,
--    @name nvarchar(max),
--    @macroVariable varchar(100),
--    @macroValue real
--@operationTypeUUID
--assignment

EXEC recipe.addParameterDefault
	@parameterDefaultUUID =:parameterDefaultUUID,
	@parameterUUID =:parameterUUID,
    @extensionTypeUUID =:extensionTypeUUID,
    @name =:name,
    @macroVariable =:macroVariable,
    @macroValue =:macroValue,
    @lastEdited=:lastEdited,
	@lastEditedBy=:lastEditedBy,
	@operationTypeUUID=:operationTypeUUID,
	@assignedCylinder=:assignedCylinder