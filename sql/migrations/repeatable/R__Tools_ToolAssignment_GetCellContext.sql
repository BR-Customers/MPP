-- =============================================
-- Procedure:   Tools.ToolAssignment_GetCellContext
-- Author:      Blue Ridge Automation
-- Created:     2026-06-16
--
-- Description:
--   Single-row "mount context" for a Cell, powering the Plant Hierarchy
--   Cell Mount Card (mount-from-location). ALWAYS returns exactly one row
--   so the card can render an empty/occupied state for mount-capable cells
--   and stay hidden elsewhere.
--
--   IsMountTarget (BIT): 1 when some ToolType maps its
--     CompatibleLocationTypeDefinitionId (migration 0018) to this cell's
--     LocationTypeDefinitionId -- i.e. the cell is a valid mount target for
--     some tool type (today: DieCastMachine, because Die -> DieCastMachine).
--     Data-driven; no hardcoded codes.
--
--   The remaining columns describe the currently-active assignment (filtered
--   UNIQUE on ReleasedAt IS NULL gives 0 or 1), NULL when the cell is empty.
--   AssignedAt is converted to Eastern at the read boundary (project ET
--   display convention). AssignedBy is the AppUser DisplayName (no Initials
--   column exists on Location.AppUser).
--
--   A non-existent / deprecated / non-cell @CellLocationId still returns one
--   row with IsMountTarget = 0 and NULL tool columns.
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolAssignment_GetCellContext
    @CellLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve the cell's definition (NULL if unknown / deprecated).
    DECLARE @DefId BIGINT;
    SELECT @DefId = l.LocationTypeDefinitionId
    FROM Location.Location l
    WHERE l.Id = @CellLocationId
      AND l.DeprecatedAt IS NULL;

    DECLARE @IsMountTarget BIT = 0;
    IF @DefId IS NOT NULL AND EXISTS (
        SELECT 1 FROM Tools.ToolType tt
        WHERE tt.CompatibleLocationTypeDefinitionId = @DefId
    )
        SET @IsMountTarget = 1;

    -- Anchor row guarantees exactly one row even with no active assignment.
    SELECT
        @IsMountTarget      AS IsMountTarget,
        ta.Id               AS ToolAssignmentId,
        ta.ToolId           AS ToolId,
        t.Code              AS ToolCode,
        t.Name              AS ToolName,
        tt.Code             AS ToolTypeCode,
        CAST(ta.AssignedAt AT TIME ZONE 'UTC'
                           AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                            AS AssignedAt,
        au.DisplayName      AS AssignedBy
    FROM (SELECT @CellLocationId AS CellLocationId) anchor
    LEFT JOIN Tools.ToolAssignment ta
        ON ta.CellLocationId = anchor.CellLocationId
       AND ta.ReleasedAt IS NULL
    LEFT JOIN Tools.Tool          t  ON t.Id  = ta.ToolId
    LEFT JOIN Tools.ToolType      tt ON tt.Id = t.ToolTypeId
    LEFT JOIN Location.AppUser    au ON au.Id = ta.AssignedByUserId;
END;
GO
