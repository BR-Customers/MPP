-- @operationTemplateId BIGINT
-- @rowsJson            NVARCHAR(MAX)
-- @appUserId           BIGINT
EXEC Parts.OperationTemplateField_SaveAll
    @OperationTemplateId = :operationTemplateId,
    @RowsJson            = :rowsJson,
    @AppUserId           = :appUserId
