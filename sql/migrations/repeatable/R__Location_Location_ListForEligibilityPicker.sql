-- =============================================
-- Procedure:   Location.Location_ListForEligibilityPicker
-- Author:      Blue Ridge Automation
-- Created:     2026-05-27
-- Version:     1.0
--
-- Description:
--   Returns every non-deprecated Location across all tiers (Site /
--   Area / WorkCenter / Cell) with the tier metadata needed to render
--   the Eligibility editor's grouped-by-tier dropdown. Sorted by
--   (HierarchyLevel ASC, Code ASC) so the dropdown reads as a natural
--   progression from broadest tier to most-specific.
--
--   The DisplayLabel column composes the human label used directly as
--   the dropdown option label: "<Code> -- <Name> (<TierName>)".
--
-- Parameters:
--   @IncludeDeprecated BIT = 0 - Include rows where DeprecatedAt IS NOT NULL.
--
-- Result set:
--   Id, Code, Name, TierName, TierOrdinal, DisplayLabel
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_ListForEligibilityPicker
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.Id,
        l.Code,
        l.Name,
        ltd.Name                                                AS TierName,
        lt.HierarchyLevel                                       AS TierOrdinal,
        l.Code + N' ' + NCHAR(8212) + N' ' + l.Name + N' (' + ltd.Name + N')' AS DisplayLabel
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
    WHERE (@IncludeDeprecated = 1 OR l.DeprecatedAt IS NULL)
    ORDER BY lt.HierarchyLevel ASC, l.Code ASC;
END;
GO
