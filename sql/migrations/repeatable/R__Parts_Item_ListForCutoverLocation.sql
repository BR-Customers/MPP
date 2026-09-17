-- =============================================
-- Procedure:   Parts.Item_ListForCutoverLocation
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.1
--
-- Description:
--   The parts the cutover scan offers once the operator has said where the
--   stock is (Location_ListCutoverSources).
--
--   COMPONENTS ONLY (v1.1). The scan's Cast part path always needs a die and
--   a cavity; a Finished Good or Sub-Assembly has neither, so offering one
--   was a dead end (the die showed AUTO with no name, no cavity tiles, and
--   Add basket refused). ItemType.Code = 'Component' on both branches below.
--
--   A line or a trim store: the Components eligible there -- the same
--   predicate as Parts.Item_ListEligibleForLocation (ancestor cascade;
--   trim-shop eligibility is recorded on the shop and reaches the store
--   through it), with the type filter added. Inlined rather than EXECed so
--   the filter can apply; keep the eligibility predicate in step with that
--   proc.
--
--   A cutover destination with NO eligibility of any kind anywhere up its
--   chain -- the warehouse -- lists every active Component: it can hold
--   anything, and nobody configures eligibility for a warehouse. The
--   fallback is limited to IsCutoverDestination rows: a LINE with no
--   eligibility still lists nothing.
--
--   Read proc: single result set, no OUTPUT params (FDS-11-011).
--   NULL @LocationId = empty result.
--
-- Result set (ordered by PartNumber):
--   Id, PartNumber, Description, MaxLotSize, MaxParts
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial.
--   2026-09-17 - 1.1 - Components only.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_ListForCutoverLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AllComponents BIT = 0;

    IF EXISTS (SELECT 1 FROM Location.Location
               WHERE Id = @LocationId AND IsCutoverDestination = 1)
       AND NOT EXISTS (SELECT 1
                       FROM Parts.v_EffectiveItemLocation eil
                       INNER JOIN Location.ufn_AncestorLocationIds(@LocationId) a
                               ON a.LocationId = eil.LocationId)
        SET @AllComponents = 1;

    SELECT i.Id, i.PartNumber, i.Description, i.MaxLotSize, i.MaxParts
    FROM Parts.Item i
    INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
    WHERE @LocationId IS NOT NULL
      AND i.DeprecatedAt IS NULL
      AND it.Code = N'Component'
      AND (@AllComponents = 1
           OR EXISTS (SELECT 1
                      FROM Parts.v_EffectiveItemLocation eil
                      INNER JOIN Location.ufn_AncestorLocationIds(@LocationId) a
                              ON a.LocationId = eil.LocationId
                      WHERE eil.ItemId = i.Id))
    ORDER BY i.PartNumber;
END;
GO
