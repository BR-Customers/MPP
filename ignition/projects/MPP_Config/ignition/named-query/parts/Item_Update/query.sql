EXEC Parts.Item_Update
    @Id               = :id,
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
