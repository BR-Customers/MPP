-- =============================================
-- Procedure:   Tools.Tool_ListMountableForCell
-- Author:      Blue Ridge Automation
-- Created:     2026-06-16
--
-- Description:
--   The active Tools that may be mounted on a given Cell RIGHT NOW -- the
--   inverse of Tools.Tool_ListCompatibleCells. Backs the Plant Hierarchy
--   Cell Mount Card's "Mount" dropdown (mount-from-location).
--
--   A tool qualifies when:
--     * it is active (DeprecatedAt IS NULL), AND
--     * its ToolType.CompatibleLocationTypeDefinitionId matches the cell's
--       LocationTypeDefinitionId, OR is NULL (unrestricted type -> any cell)
--       -- same compatibility rule as Tool_ListCompatibleCells (migration
--       0018), kept in SQL, AND
--     * it is not currently mounted anywhere (no ToolAssignment with
--       ReleasedAt IS NULL).
--
--   Unknown / deprecated @CellLocationId -> empty result.
--
-- Result set: Id, Code, Name -- ordered by Code. Shape feeds
--   BlueRidge.Parts.Tool.getMountableToolsForCell -> [{label, value}].
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_ListMountableForCell
    @CellLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DefId BIGINT;
    SELECT @DefId = l.LocationTypeDefinitionId
    FROM Location.Location l
    WHERE l.Id = @CellLocationId
      AND l.DeprecatedAt IS NULL;

    IF @DefId IS NULL
        RETURN;  -- unknown / deprecated cell -> nothing mountable

    SELECT
        t.Id,
        t.Code,
        t.Name
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
    WHERE t.DeprecatedAt IS NULL
      AND (tt.CompatibleLocationTypeDefinitionId = @DefId
           OR tt.CompatibleLocationTypeDefinitionId IS NULL)
      AND NOT EXISTS (
          SELECT 1 FROM Tools.ToolAssignment ta
          WHERE ta.ToolId = t.Id
            AND ta.ReleasedAt IS NULL
      )
    ORDER BY t.Code;
END;
GO
