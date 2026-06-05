-- =============================================
-- Procedure:   Tools.Tool_ListCompatibleCells
-- Author:      Blue Ridge Automation
-- Created:     2026-06-05
-- Version:     1.0
--
-- Description:
--   Returns the active Cell-tier Locations a given tool may be mounted on,
--   filtered by the tool's ToolType.CompatibleLocationTypeDefinitionId
--   (migration 0018). Backs the Mount-to-Cell dropdown so a Die Cast Die
--   lists only Die Cast Machine cells.
--
--   Compatibility rule (kept in SQL, not the Jython layer):
--     * ToolType has a CompatibleLocationTypeDefinitionId
--         -> only Cells of that kind are returned.
--     * CompatibleLocationTypeDefinitionId IS NULL (unmapped tool type)
--         -> all Cell-tier Locations are returned (non-blocking fallback).
--     * Unknown / deprecated tool id -> empty result (no compatible def
--       resolves, but the Cell-tier filter still returns all Cells; see
--       note below).
--
-- Parameters:
--   @ToolId BIGINT - Required. Tools.Tool.Id whose type drives the filter.
--
-- Result set:
--   Id, Code, Name, LocationTypeDefinitionId, ParentLocationId,
--   SortOrder, DeprecatedAt (always NULL given the active filter).
--   Ordered by Name ASC. Shape matches Location.Location_ListByTier so the
--   dropdown shaping in BlueRidge.Parts.Tool.getCellsForDropdown is reused.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType, Location.Location,
--           Location.LocationTypeDefinition, Location.LocationType
--
-- Change Log:
--   2026-06-05 - 1.0 - Initial version (Mount-to-Cell tool-type filter)
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_ListCompatibleCells
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve the tool's compatible cell-kind. NULL => no restriction.
    DECLARE @CompatibleDefId BIGINT;
    SELECT @CompatibleDefId = tt.CompatibleLocationTypeDefinitionId
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
    WHERE t.Id = @ToolId;

    DECLARE @CellTierId BIGINT = (
        SELECT Id FROM Location.LocationType WHERE Code = N'Cell'
    );

    IF @CellTierId IS NULL
        RETURN;

    SELECT
        loc.Id,
        loc.Code,
        loc.Name,
        loc.LocationTypeDefinitionId,
        loc.ParentLocationId,
        loc.SortOrder,
        loc.DeprecatedAt
    FROM Location.Location loc
    INNER JOIN Location.LocationTypeDefinition ltd
        ON ltd.Id = loc.LocationTypeDefinitionId
    WHERE ltd.LocationTypeId = @CellTierId
      AND loc.DeprecatedAt IS NULL
      AND (@CompatibleDefId IS NULL
           OR loc.LocationTypeDefinitionId = @CompatibleDefId)
    ORDER BY loc.Name;
END;
GO
