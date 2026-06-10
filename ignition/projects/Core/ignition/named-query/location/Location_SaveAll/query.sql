EXEC Location.Location_SaveAll
    @Id                       = :id,
    @ParentLocationId         = :parentLocationId,
    @LocationTypeDefinitionId = :locationTypeDefinitionId,
    @Name                     = :name,
    @Code                     = :code,
    @Description              = :description,
    @SortOrder                = :sortOrder,
    @AppUserId                = :appUserId,
    @AttributeValuesJson      = :attributeValuesJson
