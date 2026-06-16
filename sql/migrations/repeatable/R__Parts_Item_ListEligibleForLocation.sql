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
--   Item can resolve at a location via more than one path.
--
--   Read proc: single result set, no status row, no OUTPUT params (FDS-11-011).
--   Empty result = no eligible items at that location (no invented 404).
--
-- Parameters:
--   @LocationId BIGINT - the resolution location (Cell/Area/etc.).
--
-- Result set (ordered by PartNumber):
--   Id, PartNumber, Description, MaxLotSize, MaxParts
--
-- Dependencies:
--   Parts.v_EffectiveItemLocation, Parts.Item
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
    WHERE eil.LocationId = @LocationId
      AND i.DeprecatedAt IS NULL
    ORDER BY i.PartNumber;
END;
GO
