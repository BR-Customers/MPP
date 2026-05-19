-- =============================================
-- Procedure:   Location.Location_ListByTier
-- Author:      Blue Ridge Automation
-- Created:     2026-05-19
-- Version:     1.0
--
-- Description:
--   Returns all active (non-deprecated) Locations whose LocationType
--   matches the given tier Code (e.g., 'Site', 'Area', 'WorkCenter',
--   'Cell', 'Workstation'). Generic read-side helper that backs any
--   tier-scoped dropdown (Areas for Defect Codes, Cells for Tool
--   Assignment, etc).
--
-- Parameters:
--   @TierCode NVARCHAR(50)  - Required. Matches Location.LocationType.Code.
--                              Returns empty if the tier code is unknown.
--
-- Result set:
--   Id, Code, Name, LocationTypeDefinitionId, ParentLocationId,
--   SortOrder, DeprecatedAt (always NULL given the active filter —
--   included for caller convenience).
--   Ordered by Name ASC.
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition,
--           Location.LocationType
--
-- Change Log:
--   2026-05-19 - 1.0 - Initial version (Defect Codes Area dropdown)
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_ListByTier
    @TierCode NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TierId BIGINT = (
        SELECT Id FROM Location.LocationType WHERE Code = @TierCode
    );

    IF @TierId IS NULL
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
    WHERE ltd.LocationTypeId = @TierId
      AND loc.DeprecatedAt  IS NULL
    ORDER BY loc.Name;
END;
GO
