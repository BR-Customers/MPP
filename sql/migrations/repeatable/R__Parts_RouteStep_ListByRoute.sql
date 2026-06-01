-- =============================================
-- Procedure:   Parts.RouteStep_ListByRoute
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Returns the ordered list of RouteStep rows for a given RouteTemplate,
--   joined to Parts.OperationTemplate for Code/Name + the OperationTemplate's
--   Area (via Location.Location) for OperationAreaName, plus a comma-joined
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
--     OperationAreaLocationId, OperationAreaName,
--     DataCollectionSummary, IsRequired, Description
--
-- Dependencies:
--   Tables: Parts.RouteStep, Parts.OperationTemplate, Location.Location,
--           Parts.OperationTemplateField, Parts.DataCollectionField
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-20 - 3.0 - Added OperationAreaName + DataCollectionSummary +
--                      OperationAreaLocationId + OperationVersionNumber
--                      projections to drive the Item Master Routes tab.
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
        ot.AreaLocationId AS OperationAreaLocationId,
        areaLoc.Name     AS OperationAreaName,
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
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    INNER JOIN Location.Location areaLoc ON areaLoc.Id = ot.AreaLocationId
    WHERE rs.RouteTemplateId = @RouteTemplateId
    ORDER BY rs.SequenceNumber;
END;
GO
