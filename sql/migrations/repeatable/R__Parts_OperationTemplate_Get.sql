-- =============================================
-- Procedure:   Parts.OperationTemplate_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Returns a single OperationTemplate row by Id, joined to
--   Parts.OperationType (role) + Parts.OperationCategory (grouping).
--   Empty result = not found.
--
-- Parameters:
--   @Id BIGINT - PK. Required.
--
-- Result set:
--   Zero or one OperationTemplate row with joined OperationType + Category.
--
-- Dependencies:
--   Tables: Parts.OperationTemplate, Parts.OperationType, Parts.OperationCategory
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-07-02 - 3.0 - AreaLocationId/AreaName -> OperationType + Category
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplate_Get
    @Id BIGINT
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
    WHERE ot.Id = @Id;
END;
GO
