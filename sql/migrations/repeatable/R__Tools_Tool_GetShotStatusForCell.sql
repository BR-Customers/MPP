-- ============================================================
-- Repeatable:  R__Tools_Tool_GetShotStatusForCell.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-04
-- Version:     1.0
-- Description: FAT #26/#27. Returns the shot status of the die CURRENTLY
--              mounted on a cell (active Tools.ToolAssignment, ReleasedAt
--              IS NULL) for the die-cast station badge. Derived indicators
--              come from Tools.ufn_ShotStatus. FDS-11-011: no OUTPUT params,
--              one result set, empty set = nothing mounted (not an error).
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.Tool_GetShotStatusForCell
    @CellLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id   AS ToolId,
        t.Code AS ToolCode,
        t.Name AS ToolName,
        t.ShotCount,
        t.ShotLimit,
        ss.ShotsRemaining,
        ss.PercentOfLimit,
        ss.IsNearLimit,
        ss.IsOverLimit
    FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId
    CROSS APPLY Tools.ufn_ShotStatus(t.ShotCount, t.ShotLimit) ss
    WHERE ta.CellLocationId = @CellLocationId
      AND ta.ReleasedAt IS NULL;
END;
GO
