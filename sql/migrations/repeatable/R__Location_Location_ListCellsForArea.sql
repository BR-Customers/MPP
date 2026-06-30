-- =============================================
-- Procedure:   Location.Location_ListCellsForArea
-- Author:      Blue Ridge Automation
-- Created:     2026-06-16
-- Version:     1.0
--
-- Description:
--   The pickable EQUIPMENT cells beneath an Area - Cell-tier Locations excluding
--   the Terminal and Printer infrastructure kinds (terminals/printers are
--   themselves Cell-tier but are never a production context). Area-scoped sibling
--   of Location.Terminal_ListContextCells (which roots at a Terminal's parent);
--   this roots at the Area itself. Feeds the die-cast entry screen's Cell
--   dropdown when the page is parameterized by Area. Recursive: equipment cells
--   any depth below the Area qualify; a deprecated intermediate prunes its subtree.
--
--   Read proc: single result set, no status row, no OUTPUT params (FDS-11-011).
--   Empty result = unknown/deprecated Area or no active equipment cells beneath it.
--
-- Parameters:
--   @AreaLocationId BIGINT - Location.Id of the Area (not validated; unknown id
--                            -> empty set).
--
-- Result set (ordered by Code):
--   LocationId, Code, Name, Kind
--
-- Dependencies:
--   Location.Location, Location.LocationTypeDefinition, Location.LocationType
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_ListCellsForArea
    @AreaLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT l.Id, l.Code, l.Name, l.LocationTypeDefinitionId
        FROM Location.Location l
        WHERE l.ParentLocationId = @AreaLocationId
          AND l.DeprecatedAt IS NULL
        UNION ALL
        SELECT c.Id, c.Code, c.Name, c.LocationTypeDefinitionId
        FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        WHERE c.DeprecatedAt IS NULL
    )
    SELECT
        d.Id     AS LocationId,
        d.Code   AS Code,
        d.Name   AS Name,
        ltd.Name AS Kind
    FROM Descendants d
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = d.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt           ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Cell'
      AND ltd.Code NOT IN (N'Terminal', N'Printer')
    ORDER BY d.Code
    OPTION (MAXRECURSION 8);  -- ISA-95 depth below an Area is <= 4 in any real plant
END;
GO
