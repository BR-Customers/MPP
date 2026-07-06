-- =============================================
-- Procedure:   Parts.OperationTemplate_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Returns OperationTemplate rows joined to Parts.OperationType (role) +
--   Parts.OperationCategory (grouping). Optionally filters to a single
--   OperationType and/or OperationCategory and/or excludes deprecated rows.
--   Replaces the former @AreaLocationId filter (and the retired _ListByArea).
--
-- Parameters:
--   @OperationTypeId     BIGINT = NULL - When supplied, filters to this role.
--   @OperationCategoryId BIGINT = NULL - When supplied, filters to this category.
--   @ActiveOnly          BIT    = 1    - When 1, excludes DeprecatedAt rows.
--
-- Result set:
--   Zero or more OperationTemplate rows with joined OperationType + Category,
--   ordered by Category, OperationType, Code, VersionNumber.
--
-- Dependencies:
--   Tables: Parts.OperationTemplate, Parts.OperationType, Parts.OperationCategory
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-07-02 - 3.0 - @AreaLocationId -> @OperationTypeId/@OperationCategoryId;
--                      joins OperationType + Category; retires _ListByArea
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplate_List
    @OperationTypeId     BIGINT = NULL,
    @OperationCategoryId BIGINT = NULL,
    @ActiveOnly          BIT    = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ot.Id,
        ot.Code,
        ot.VersionNumber,
        ot.Name,
        ot.OperationTypeId,
        typ.Code             AS OperationTypeCode,
        typ.Name             AS OperationTypeName,
        cat.Id               AS OperationCategoryId,
        cat.Code             AS OperationCategoryCode,
        cat.Name             AS OperationCategoryName,
        ot.Description,
        ot.CreatedAt,
        ot.DeprecatedAt
    FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType     typ ON typ.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationCategory cat ON cat.Id = typ.OperationCategoryId
    WHERE (@OperationTypeId IS NULL OR ot.OperationTypeId = @OperationTypeId)
      AND (@OperationCategoryId IS NULL OR typ.OperationCategoryId = @OperationCategoryId)
      AND (@ActiveOnly = 0 OR ot.DeprecatedAt IS NULL)
    ORDER BY cat.Code, typ.Code, ot.Code, ot.VersionNumber;
END;
GO
