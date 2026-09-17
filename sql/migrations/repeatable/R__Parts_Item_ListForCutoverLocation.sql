-- =============================================
-- Procedure:   Parts.Item_ListForCutoverLocation
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
--
-- Description:
--   The parts the cutover scan offers once the operator has said where the
--   stock is (Location_ListCutoverSources).
--
--   A line or a trim store: the parts eligible there -- exactly
--   Parts.Item_ListEligibleForLocation (ancestor cascade; trim-shop
--   eligibility is recorded on the shop and reaches the store through it).
--
--   A cutover destination with NOTHING eligible anywhere up its chain -- the
--   warehouse -- lists every active part: it can hold anything, and nobody
--   configures eligibility for a warehouse. The fallback is deliberately
--   limited to IsCutoverDestination rows: a LINE with no eligibility still
--   lists nothing, because offering every part at a line would let stock be
--   counted onto a line that cannot run it.
--
--   Same result shape as Item_ListEligibleForLocation so the Python dropdown
--   shaping is shared.
--
--   Read proc: single result set, no OUTPUT params (FDS-11-011).
--   NULL @LocationId = empty result.
--
-- Result set (ordered by PartNumber):
--   Id, PartNumber, Description, MaxLotSize, MaxParts
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_ListForCutoverLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
    BEGIN
        SELECT i.Id, i.PartNumber, i.Description, i.MaxLotSize, i.MaxParts
        FROM Parts.Item i
        WHERE 1 = 0;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM Location.Location
               WHERE Id = @LocationId AND IsCutoverDestination = 1)
       AND NOT EXISTS (SELECT 1
                       FROM Parts.v_EffectiveItemLocation eil
                       INNER JOIN Location.ufn_AncestorLocationIds(@LocationId) a
                               ON a.LocationId = eil.LocationId)
    BEGIN
        SELECT i.Id, i.PartNumber, i.Description, i.MaxLotSize, i.MaxParts
        FROM Parts.Item i
        WHERE i.DeprecatedAt IS NULL
        ORDER BY i.PartNumber;
        RETURN;
    END;

    EXEC Parts.Item_ListEligibleForLocation @LocationId = @LocationId;
END;
GO
