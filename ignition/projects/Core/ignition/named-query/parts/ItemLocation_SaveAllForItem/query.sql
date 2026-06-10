-- @itemId    BIGINT
-- @rowsJson  NVARCHAR(MAX)
-- @appUserId BIGINT
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = :itemId,
    @RowsJson  = :rowsJson,
    @AppUserId = :appUserId
