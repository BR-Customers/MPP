-- =============================================
-- Procedure:   Tools.Tool_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.0
--
-- Description:
--   Returns a single Tool row by Id with joined ToolType, StatusCode,
--   and DieRank for display. Empty result = not found.
--
-- Parameters:
--   @Id BIGINT - PK. Required.
--
-- Result set:
--   Zero or one Tool row with joined display fields.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType, Tools.ToolStatusCode, Tools.DieRank
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id,
        t.ToolTypeId,
        tt.Code              AS ToolTypeCode,
        tt.Name              AS ToolTypeName,
        tt.HasCavities,
        t.Code,
        t.Name,
        t.Description,
        t.DieRankId,
        dr.Code              AS DieRankCode,
        dr.Name              AS DieRankName,
        t.StatusCodeId,
        sc.Code              AS StatusCode,
        sc.Name              AS StatusName,
        t.CreatedAt,
        t.UpdatedAt,
        t.CreatedByUserId,
        t.UpdatedByUserId,
        t.DeprecatedAt,
        t.ShotCount,
        t.ShotLimit,
        ss.ShotsRemaining,
        ss.PercentOfLimit,
        ss.IsNearLimit,
        ss.IsOverLimit
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType       tt ON tt.Id = t.ToolTypeId
    INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
    LEFT  JOIN Tools.DieRank        dr ON dr.Id = t.DieRankId
    CROSS APPLY Tools.ufn_ShotStatus(t.ShotCount, t.ShotLimit) ss
    WHERE t.Id = @Id;
END;
GO
