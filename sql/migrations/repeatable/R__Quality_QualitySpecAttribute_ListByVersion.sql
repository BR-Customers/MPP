-- =============================================
-- Procedure:   Quality.QualitySpecAttribute_ListByVersion
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     1.1
--
-- Description:
--   Returns all attributes for a given QualitySpecVersion,
--   ordered by SortOrder ascending.
--
-- Parameters (input):
--   @QualitySpecVersionId BIGINT - Required.
--
-- Returns (result set):
--   All attributes with their configuration.
--
-- Dependencies:
--   Tables: Quality.QualitySpecAttribute, Parts.Uom
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Quality Spec Config Tool: join Parts.Uom for
--                       UomId/UomCode/UomName display columns
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecAttribute_ListByVersion
    @QualitySpecVersionId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.Id,
        a.QualitySpecVersionId,
        a.AttributeName,
        a.DataType,
        a.Uom,
        a.UomId,
        u.Code AS UomCode,
        u.Name AS UomName,
        a.TargetValue,
        a.LowerLimit,
        a.UpperLimit,
        a.IsRequired,
        a.SortOrder
    FROM Quality.QualitySpecAttribute a
    LEFT JOIN Parts.Uom u ON u.Id = a.UomId
    WHERE a.QualitySpecVersionId = @QualitySpecVersionId
    ORDER BY a.SortOrder ASC;
END
GO
