-- @toolId    BIGINT
-- @rowsJson  NVARCHAR(MAX)
-- @appUserId BIGINT
EXEC Tools.ToolAttribute_SaveAll
    @ToolId    = :toolId,
    @RowsJson  = :rowsJson,
    @AppUserId = :appUserId
