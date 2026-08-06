-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-15
-- Version:     1.0
--
-- Description:
--   Returns a single downtime reason code by Id with joined
--   Area/type/source names. Empty result if not found.
--
-- Parameters (input):
--   @Id BIGINT - Required.
--
-- Returns (result set):
--   Single row (or empty) with downtime reason code fields.
--
-- Dependencies:
--   Tables: Oee.DowntimeReasonCode, Location.Location,
--           Oee.DowntimeReasonType, Oee.DowntimeSourceCode
--
-- Change Log:
--   2026-04-15 - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        drc.Id,
        drc.Code,
        drc.Description,
        drc.OperationCategoryId,
        oc.Name             AS CategoryName,
        drc.DowntimeReasonTypeId,
        drt.Name            AS ReasonTypeName,
        drc.DowntimeSourceCodeId,
        dsc.Name            AS SourceCodeName,
        drc.IsExcused,
        drc.CreatedAt,
        drc.DeprecatedAt
    FROM Oee.DowntimeReasonCode drc
    LEFT JOIN Parts.OperationCategory oc  ON drc.OperationCategoryId  = oc.Id
    LEFT JOIN Oee.DowntimeReasonType  drt ON drc.DowntimeReasonTypeId = drt.Id
    LEFT JOIN Oee.DowntimeSourceCode  dsc ON drc.DowntimeSourceCodeId = dsc.Id
    WHERE drc.Id = @Id;
END
GO
