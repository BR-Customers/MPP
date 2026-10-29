-- =============================================
-- Repeatable:  R__Oee_ufn_zz_AreaFamily.sql
-- Object:      Oee.ufn_AreaFamily
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: Where ANY location lands on the OEE dashboard (spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.2, 6.4). Used to place a reject by its CellLocationId.
--              Always ONE row:
--                AreaFamily           diecast | trim | ma | NULL
--                PlacementLocationId  the unit the location belongs to:
--                  - the location or an ancestor is an OEE location -> that
--                    chain's TOP unit (a line terminal -> the line, a station
--                    -> its line, a press terminal -> the press);
--                  - otherwise, OEE units BENEATH it -> the location itself.
--                    That is the trim shop: trim scrap is recorded against the
--                    shop, and the shop is where trim quality lives (D5);
--                  - otherwise NULL (no unit above or below).
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
    WITH Down AS (
        SELECT c.Id
        FROM Location.Location c
        WHERE c.ParentLocationId = @LocationId
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Down d ON c.ParentLocationId = d.Id
    )
    SELECT
        COALESCE(up.AreaFamily, dn.AreaFamily) AS AreaFamily,
        CASE WHEN up.TopUnitLocationId IS NOT NULL THEN up.TopUnitLocationId
             WHEN dn.AreaFamily IS NOT NULL        THEN @LocationId
        END                                    AS PlacementLocationId,
        ar.Id                                  AS ProductionAreaId
    FROM (SELECT 1 AS One) one
    OUTER APPLY (
        SELECT TOP 1 u.TopUnitLocationId, u.AreaFamily
        FROM Location.ufn_AncestorLocationIds(@LocationId) x
        INNER JOIN Oee.ufn_OeeUnits() u ON u.LocationId = x.LocationId
    ) up
    OUTER APPLY (
        SELECT TOP 1 u.AreaFamily
        FROM Down d
        INNER JOIN Oee.ufn_OeeUnits() u ON u.LocationId = d.Id
        ORDER BY u.IsStation, u.LocationId
    ) dn
    OUTER APPLY (
        SELECT TOP 1 a.Id
        FROM Location.ufn_AncestorLocationIds(@LocationId) x
        INNER JOIN Location.Location a                ON a.Id = x.LocationId
        INNER JOIN Location.LocationTypeDefinition ad ON ad.Id = a.LocationTypeDefinitionId
        WHERE ad.Code = N'ProductionArea'
    ) ar
);
GO
