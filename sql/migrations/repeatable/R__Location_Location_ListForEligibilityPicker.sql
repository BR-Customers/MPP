-- =============================================
-- Procedure:   Location.Location_ListForEligibilityPicker
-- Author:      Blue Ridge Automation
-- Created:     2026-05-27
-- Version:     1.1
--
-- Description:
--   Returns the non-deprecated Locations eligibility may target, with the
--   tier metadata needed to render the Eligibility editor's grouped-by-tier
--   dropdown. Sorted by (HierarchyLevel ASC, Code ASC).
--
--   v1.1 (Jacques 2026-07-06): eligibility is configured at the AREA and
--   PRODUCTION LINE (WorkCenter) tiers ONLY -- HierarchyLevel IN (2, 3).
--   Cell-tier rows (terminals, printers, machines) and Site/Enterprise are
--   excluded from the picker. Existing Cell-tier eligibility rows still
--   resolve through the hierarchy cascade; they just cannot be authored
--   from the picker any more (migrate dev-data cell rows up to their line).
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
      AND lt.HierarchyLevel IN (2, 3)   -- Area + WorkCenter (line) tiers only (v1.1)
    ORDER BY lt.HierarchyLevel ASC, l.Code ASC;
END;
GO
