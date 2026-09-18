-- =============================================
-- Procedure:   Location.Location_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.1
--
-- Description:
--   Returns a single Location row by Id, joined to LocationTypeDefinition
--   and LocationType for display names.
--   Read-only proc — empty result means not found.
--
-- Parameters:
--   @Id BIGINT  - PK of the Location to retrieve. Required.
--
-- Result set:
--   Zero or one row from Location.Location with joined display names.
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition, Location.LocationType
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-13 - 1.1 - Added Icon column from LocationTypeDefinition
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-09-17 - 2.1 - IsOeeEnabled (OEE-enabled locations spec).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_Get
    @Id BIGINT
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
        ltd.Icon   AS LocationTypeDefinitionIcon,
        lt.Name    AS LocationTypeName,
        l.IsOeeEnabled
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.Id = @Id;
END;
GO
