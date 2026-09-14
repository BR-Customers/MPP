-- ============================================================
-- Repeatable:  R__Location_Location_ListDieCastMachinesForItem.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-14
-- Version:     1.0
-- Description: Which die cast machines the inventory cutover scan offers for a
--              part.
--
--              EXACT MATCH AT THE MACHINE TIER, not the FDS-03-014 ancestor
--              cascade that Location_ListMachiningDestinations uses. Measured
--              against Dev 2026-09-14, the cascade returns ELEVEN machines for
--              every part in the plant: eligibility is recorded predominantly
--              at the Area (135 rows) and Line (272 rows) tiers and every
--              machine beneath an eligible area inherits it. A filter that
--              returns the same rows regardless of input is not a filter. The
--              machine-tier rows (9 in Dev) are the deliberate signal -- the
--              six 6MA parts were mapped to DC1-M10 on purpose.
--
--              FALLBACK: a part with NO machine-tier row gets EVERY active die
--              cast machine, flagged IsEligible = 0. The operator must always
--              be able to record what the paper tag says; eligibility is a
--              shortlist, never a gate on the scan.
--
--              ORDERED BY (AreaCode, Code), NOT Name: machine Names collide
--              across areas -- DC1-M01 and DC2-M01 are both 'Machine 01' -- so
--              the area is what disambiguates them in a picker.
--
--              Read proc: no @Status/@Message, no OUTPUT params, one result
--              set; an empty rowset means no die cast machines are configured
--              at all (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListDieCastMachinesForItem
    @ItemId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Decide the fallback ONCE rather than per row: either the item has
    -- machine-tier eligibility (return exactly those) or it has none (return
    -- every active machine).
    DECLARE @EligibleCount INT = (
        SELECT COUNT(*)
        FROM Location.Location m
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = m.LocationTypeDefinitionId
        WHERE ltd.Code = N'DieCastMachine'
          AND m.DeprecatedAt IS NULL
          AND @ItemId IS NOT NULL
          AND EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.ItemId = @ItemId
                        AND il.LocationId = m.Id
                        AND il.DeprecatedAt IS NULL));

    SELECT
        m.Id,
        m.Code,
        m.Name,
        area.Code AS AreaCode,
        area.Name AS AreaName,
        CAST(CASE WHEN @EligibleCount = 0 THEN 0 ELSE 1 END AS BIT) AS IsEligible
    FROM Location.Location m
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = m.LocationTypeDefinitionId
    LEFT JOIN Location.Location area ON area.Id = m.ParentLocationId
    WHERE ltd.Code = N'DieCastMachine'
      AND m.DeprecatedAt IS NULL
      AND (@EligibleCount = 0
           OR EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.ItemId = @ItemId
                        AND il.LocationId = m.Id
                        AND il.DeprecatedAt IS NULL))
    ORDER BY area.Code, m.Code;
END;
GO
