-- =============================================
-- Procedure:   Parts.ItemLocation_ListByItem
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Returns all active eligibility pairings for a given Item, joined
--   to Location.Location, Location.LocationTypeDefinition (Name AS
--   DefinitionName), and Location.LocationType (HierarchyLevel AS
--   TierOrdinal). Only rows where DeprecatedAt IS NULL are returned.
--   Ordered by tier then code so the editor sees rows in canonical
--   (Site -> Area -> WorkCenter -> Cell) order.
--
-- Parameters:
--   @ItemId BIGINT - Required.
--
-- Result set:
--   ItemLocation rows + LocationName, LocationCode, DefinitionName,
--   TierOrdinal.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: consumption metadata exposed (OI-18)
--   2026-05-27 - 3.0 - Phase 8 Eligibility editor: add TierOrdinal,
--                      re-sort by (TierOrdinal, Code) for canonical
--                      display order.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_ListByItem
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        il.Id,
        il.ItemId,
        il.LocationId,
        l.Name                  AS LocationName,
        l.Code                  AS LocationCode,
        ltd.Name                AS DefinitionName,
        lt.HierarchyLevel       AS TierOrdinal,
        il.MinQuantity,
        il.MaxQuantity,
        il.DefaultQuantity,
        il.IsConsumptionPoint,
        il.CreatedAt,
        il.DeprecatedAt
    FROM Parts.ItemLocation il
    INNER JOIN Location.Location               l   ON l.Id   = il.LocationId
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType           lt  ON lt.Id  = ltd.LocationTypeId
    WHERE il.ItemId = @ItemId
      AND il.DeprecatedAt IS NULL
    ORDER BY lt.HierarchyLevel ASC, l.Code ASC;
END;
GO
