-- =============================================
-- Procedure:   Quality.DefectCode_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.0
--
-- Description:
--   Returns a single defect code by Id, with its resolved
--   OperationCategory name (LEFT JOIN; NULL = plant-wide).
--
-- Parameters (input):
--   @Id BIGINT - Required.
--
-- Returns (result set):
--   Single row with all defect code fields.
--
-- Dependencies:
--   Tables: Quality.DefectCode, Parts.OperationCategory
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-08-04 - 2.0 - Return OperationCategoryId + CategoryName instead of
--                       AreaLocationId + AreaName.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dc.Id,
        dc.Code,
        dc.Description,
        dc.OperationCategoryId,
        oc.Name                AS CategoryName,
        dc.IsExcused,
        dc.CreatedAt,
        dc.DeprecatedAt
    FROM Quality.DefectCode dc
    LEFT JOIN Parts.OperationCategory oc ON dc.OperationCategoryId = oc.Id
    WHERE dc.Id = @Id;
END
GO
