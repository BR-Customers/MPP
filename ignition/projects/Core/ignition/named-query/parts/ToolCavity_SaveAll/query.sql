-- @toolId    BIGINT
-- @rowsJson  NVARCHAR(MAX)
-- @appUserId BIGINT
EXEC Tools.ToolCavity_SaveAll
    @ToolId    = :toolId,
    @RowsJson  = :rowsJson,
    @AppUserId = :appUserId
