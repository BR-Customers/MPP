-- =============================================
-- Procedure:   Parts.RouteStep_ListByRoute
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     4.0
--
-- Description:
--   Returns the ordered list of RouteStep rows for a given RouteTemplate,
--   joined to Parts.OperationTemplate for Code/Name + the OperationTemplate's
--   OperationType (role) + OperationCategory (grouping), plus a comma-joined
--   summary of the OperationTemplate's active data-collection fields.
--   Ordered by SequenceNumber ascending.
--
-- Parameters:
--   @RouteTemplateId BIGINT - Required.
--
-- Result set:
--   Zero or more RouteStep rows ordered by SequenceNumber, with:
--     Id, RouteTemplateId, SequenceNumber, OperationTemplateId,
--     OperationCode, OperationName, OperationVersionNumber,
--     OperationTypeId, OperationTypeCode, OperationTypeName,
--     OperationCategoryName, DataCollectionSummary, IsRequired, Description
--
-- Dependencies:
--   Tables: Parts.RouteStep, Parts.OperationTemplate, Parts.OperationType,
--           Parts.OperationCategory, Parts.OperationTemplateField,
--           Parts.DataCollectionField
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-20 - 3.0 - Added OperationAreaName + DataCollectionSummary +
--                      OperationAreaLocationId + OperationVersionNumber
--                      projections to drive the Item Master Routes tab.
--   2026-07-02 - 4.0 - Area -> OperationType + Category (operation-type restructure)
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteStep_ListByRoute
    @RouteTemplateId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        rs.Id,
        rs.RouteTemplateId,
        rs.SequenceNumber,
        rs.OperationTemplateId,
        ot.Code          AS OperationCode,
        ot.Name          AS OperationName,
        ot.VersionNumber AS OperationVersionNumber,
        ot.OperationTypeId,
        typ.Code         AS OperationTypeCode,
        typ.Name         AS OperationTypeName,
        cat.Name         AS OperationCategoryName,
        ISNULL((
            SELECT STRING_AGG(dcf.Code, N', ') WITHIN GROUP (ORDER BY dcf.Code)
            FROM Parts.OperationTemplateField otf
            INNER JOIN Parts.DataCollectionField dcf ON dcf.Id = otf.DataCollectionFieldId
            WHERE otf.OperationTemplateId = rs.OperationTemplateId
              AND otf.DeprecatedAt IS NULL
        ), N'')          AS DataCollectionSummary,
        rs.IsRequired,
        rs.Description
    FROM Parts.RouteStep rs
    INNER JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
    INNER JOIN Parts.OperationType     typ ON typ.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationCategory cat ON cat.Id = typ.OperationCategoryId
    WHERE rs.RouteTemplateId = @RouteTemplateId
    ORDER BY rs.SequenceNumber;
END;
GO
