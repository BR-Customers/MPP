-- =============================================
-- Procedure:   Location.Location_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Returns Location rows with optional filtering by ParentLocationId
--   and/or LocationTypeDefinitionId. Optionally includes deprecated records.
--   Orders results by SortOrder ascending. Joins to LocationTypeDefinition
--   and LocationType for display names.
--   Read-only proc — empty result means no matching rows.
--
-- Parameters:
--   @ParentLocationId BIGINT NULL            - Filter by parent. NULL = root-level locations.
--                                               Omit (leave default) to skip parent filtering.
--   @LocationTypeDefinitionId BIGINT NULL    - Filter by definition type. NULL = no filtering.
--   @IncludeDeprecated BIT = 0              - When 1, includes deprecated locations in results.
--   @FilterByParent BIT = 0                  - When 1, applies ParentLocationId filter.
--   @Filter NVARCHAR(200) = NULL             - Free-text search; restricts to rows whose
--                                               Name or Code contains the text (LIKE).
--                                               NULL/'' = no text filtering. Used by the
--                                               Plant Hierarchy search box.
--
-- Result set:
--   Location columns plus LocationTypeDefinitionName, LocationTypeName, and the
--   definition's Icon (for the search-result tree nodes).
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition, Location.LocationType
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-06-29 - 2.1 - Added @Filter text search + Icon column (Plant Hierarchy search)
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_List
    @ParentLocationId          BIGINT = NULL,
    @LocationTypeDefinitionId  BIGINT = NULL,
    @IncludeDeprecated         BIT    = 0,
    @FilterByParent            BIT    = 0,
    @Filter                    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.Id,
        l.LocationTypeDefinitionId,
        l.ParentLocationId,
        l.Name,
        l.Code,
        l.Description,
        l.SortOrder,
        l.CreatedAt,
        l.DeprecatedAt,
        ltd.Name   AS LocationTypeDefinitionName,
        lt.Name    AS LocationTypeName,
        ltd.Icon   AS Icon
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE (@IncludeDeprecated = 1 OR l.DeprecatedAt IS NULL)
      AND (@FilterByParent = 0 OR
           (@ParentLocationId IS NULL AND l.ParentLocationId IS NULL) OR
           (l.ParentLocationId = @ParentLocationId))
      AND (@LocationTypeDefinitionId IS NULL OR l.LocationTypeDefinitionId = @LocationTypeDefinitionId)
      AND (@Filter IS NULL OR @Filter = ''
           OR l.Name LIKE '%' + @Filter + '%'
           OR l.Code LIKE '%' + @Filter + '%')
    ORDER BY l.SortOrder ASC;
END;
GO
