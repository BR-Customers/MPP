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
--   @LocationId        BIGINT - the resolution location (typically the scanned Cell).
--   @OperationTypeCode NVARCHAR(50) = NULL - optional route-role filter (v2.1).
--       When supplied (e.g. 'DieCast'), only Items whose non-deprecated route
--       carries a step of that OperationType role are returned - the SAME
--       predicate as parts/OperationTemplate_GetForRouteRole (the no-template
--       gate), so the dropdown and the Create gate can never disagree.
--       NULL = no route filter (all existing callers unchanged).
--
-- Result set (ordered by PartNumber):
--   Id, PartNumber, Description, MaxLotSize, MaxParts
--
-- Change Log:
--   2026-06-16 - 1.0 - Initial (exact-location match).
--   2026-06-30 - 2.0 - FDS-03-014 hierarchy cascade: match @LocationId + ancestors
--                      via Location.ufn_AncestorLocationIds (was exact-match, which
--                      left the die-cast cell dropdown empty for area-configured items).
--   2026-07-07 - 2.1 - Optional @OperationTypeCode route-role filter (smoke finding:
--                      the die-cast Item dropdown must be eligibility AND
--                      has-DieCast-route-step, not eligibility alone).
--
-- Dependencies:
--   Parts.v_EffectiveItemLocation, Parts.Item, Location.ufn_AncestorLocationIds,
--   Parts.RouteTemplate / RouteStep / OperationTemplate / OperationType (v2.1 filter)
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_ListEligibleForLocation
    @LocationId        BIGINT,
    @OperationTypeCode NVARCHAR(50) = NULL
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
      -- v2.1 route-role filter: mirror of OperationTemplate_GetForRouteRole's
      -- qualification (any non-deprecated route version carrying a step whose
      -- OperationType matches), so list-membership == gate-pass.
      AND (@OperationTypeCode IS NULL OR EXISTS (
            SELECT 1
            FROM Parts.RouteTemplate rt
            INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
            INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
            INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
            WHERE rt.ItemId = i.Id
              AND rt.DeprecatedAt IS NULL
              AND ot.DeprecatedAt IS NULL
              AND oty.Code = @OperationTypeCode))
    ORDER BY i.PartNumber;
END;
GO
