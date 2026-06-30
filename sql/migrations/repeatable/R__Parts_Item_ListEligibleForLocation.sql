-- =============================================
-- Procedure:   Parts.Item_ListEligibleForLocation
-- Author:      Blue Ridge Automation
-- Created:     2026-06-16
-- Version:     1.0
--
-- Description:
--   The Items eligible to be produced/handled at a given Location, per
--   Parts.v_EffectiveItemLocation (Direct U BomDerived). Feeds the die-cast
--   entry screen's Item dropdown (eligibility-constrained). DISTINCT because an
--   Item can resolve at a location via more than one path / tier.
--
--   Hierarchy cascade (FDS-03-014 / FDS-02-012): an Item is eligible at
--   @LocationId if configured there OR at ANY ancestor tier
--   (Cell -> WorkCenter -> Area -> Site). Engineering configures eligibility at
--   the coarsest appropriate tier ("Part 5G0-C eligible across all of Die Cast
--   Area" = one row), so a Cell-level dropdown MUST surface the ancestor Area's
--   eligible Items. Resolution walk encapsulated in Location.ufn_AncestorLocationIds.
--
--   Read proc: single result set, no status row, no OUTPUT params (FDS-11-011).
--   Empty result = no eligible items at that location (no invented 404).
--
-- Parameters:
--   @LocationId BIGINT - the resolution location (typically the scanned Cell).
--
-- Result set (ordered by PartNumber):
--   Id, PartNumber, Description, MaxLotSize, MaxParts
--
-- Change Log:
--   2026-06-16 - 1.0 - Initial (exact-location match).
--   2026-06-30 - 2.0 - FDS-03-014 hierarchy cascade: match @LocationId + ancestors
--                      via Location.ufn_AncestorLocationIds (was exact-match, which
--                      left the die-cast cell dropdown empty for area-configured items).
--
-- Dependencies:
--   Parts.v_EffectiveItemLocation, Parts.Item, Location.ufn_AncestorLocationIds
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_ListEligibleForLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT
        i.Id,
        i.PartNumber,
        i.Description,
        i.MaxLotSize,
        i.MaxParts
    FROM Parts.v_EffectiveItemLocation eil
    INNER JOIN Parts.Item i ON i.Id = eil.ItemId
    WHERE eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LocationId))
      AND i.DeprecatedAt IS NULL
    ORDER BY i.PartNumber;
END;
GO
