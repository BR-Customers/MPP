EXEC Parts.Item_Create
    @PartNumber       = :partNumber,
    @ItemTypeId       = :itemTypeId,
    @Description      = :description,
    @MacolaPartNumber = :macolaPartNumber,
    @DefaultSubLotQty = :defaultSubLotQty,
    @MaxLotSize       = :maxLotSize,
    @UomId            = :uomId,
    @UnitWeight       = :unitWeight,
    @WeightUomId      = :weightUomId,
    @CountryOfOrigin  = :countryOfOrigin,
    @MaxParts         = :maxParts,
    @AppUserId        = :appUserId
