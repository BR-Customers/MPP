-- =============================================
-- Repeatable:  R__Oee_ufn_zz_AreaFamily.sql
-- Object:      Oee.ufn_AreaFamily
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: Where ANY location lands on the OEE dashboard (spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.2, 6.4). Places a reject by its CellLocationId, trim good
--              by its terminal, M&A good by the LOT's creating terminal.
--              Always ONE row:
--                AreaFamily           diecast | trim | ma | NULL
--                PlacementLocationId  where it is booked:
--                  - the location or an ancestor is an OEE location -> that
--                    chain's TOP unit (a line terminal -> the line, a station
--                    -> its line, a press terminal -> the press);
--                  - otherwise its ProductionArea (at or above it), when OEE
--                    units sit in that area. That is the trim shop: trim
--                    scrap and the shop terminal's checkpoints are recorded
--                    against the shop, and the shop is where trim quality
--                    lives (D5). PlacementIsArea = 1;
--                  - otherwise NULL (no unit above, no units in its area).
--                PlacementIsArea      1 when the placement is a ProductionArea
--                                     (counts on the area group, no unit tile).
--                ProductionAreaId     the ProductionArea at or above it.
--              FILE NAME IS ORDER-SENSITIVE -- 'zz_' is a deploy-order marker
--              (it calls Oee.ufn_OeeUnits; functions get no deferred name
--              resolution).
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_AreaFamily (@LocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        COALESCE(up.AreaFamily, au.AreaFamily)            AS AreaFamily,
        CASE WHEN up.TopUnitLocationId IS NOT NULL THEN up.TopUnitLocationId
             WHEN au.AreaFamily IS NOT NULL        THEN ar.Id
        END                                               AS PlacementLocationId,
        CAST(CASE WHEN up.TopUnitLocationId IS NULL AND au.AreaFamily IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT)               AS PlacementIsArea,
        ar.Id                                             AS ProductionAreaId
    FROM (SELECT 1 AS One) one
    OUTER APPLY (
        SELECT TOP 1 u.TopUnitLocationId, u.AreaFamily
        FROM Location.ufn_AncestorLocationIds(@LocationId) x
        INNER JOIN Oee.ufn_OeeUnits() u ON u.LocationId = x.LocationId
    ) up
    OUTER APPLY (
        SELECT TOP 1 a.Id
        FROM Location.ufn_AncestorLocationIds(@LocationId) x
        INNER JOIN Location.Location a                ON a.Id = x.LocationId
        INNER JOIN Location.LocationTypeDefinition ad ON ad.Id = a.LocationTypeDefinitionId
        WHERE ad.Code = N'ProductionArea'
    ) ar
    OUTER APPLY (
        SELECT TOP 1 u.AreaFamily
        FROM Oee.ufn_OeeUnits() u
        WHERE u.ProductionAreaId = ar.Id
        ORDER BY u.IsStation, u.LocationId
    ) au
);
GO
