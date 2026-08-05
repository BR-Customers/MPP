-- =============================================
-- Procedure:   Tools.Tool_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.0
--
-- Description:
--   Returns Tool rows with joined ToolType.Code + StatusCode.Code +
--   DieRank.Code for display. Filterable by ToolTypeId and StatusCode.
--   Ordered by ToolType SortOrder then Tool.Code.
--
-- Parameters:
--   @ToolTypeId BIGINT = NULL        - When set, filters by ToolType.
--   @StatusCode NVARCHAR(30) = NULL  - When set, filters by status code string.
--   @IncludeDeprecated BIT = 0       - When 1, includes DeprecatedAt IS NOT NULL.
--
-- Result set:
--   Tool rows with ToolTypeCode, ToolTypeName, StatusCode, StatusName,
--   DieRankCode, DieRankName.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType, Tools.ToolStatusCode, Tools.DieRank
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_List
    @ToolTypeId         BIGINT         = NULL,
    @StatusCode         NVARCHAR(30)   = NULL,
    @IncludeDeprecated  BIT            = 0
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
    WHERE (@IncludeDeprecated = 1 OR t.DeprecatedAt IS NULL)
      AND (@ToolTypeId IS NULL OR t.ToolTypeId = @ToolTypeId)
      AND (@StatusCode IS NULL OR sc.Code = @StatusCode)
    ORDER BY tt.SortOrder, t.Code;
END;
GO
