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
--                  - the location or an ancestor is an active OEE location ->
--                    the TOPMOST one in the chain, the unit (a line terminal ->
--                    the line, a station -> its line, a press terminal -> the
--                    press). Family from that unit's definition, as
--                    Oee.ufn_OeeUnits: DieCastMachine -> diecast, TrimPress ->
--                    trim, anything else -> ma;
--                  - otherwise its ProductionArea (at or above it), when active
--                    OEE units sit directly under that area. That is the trim
--                    shop: trim scrap and the shop terminal's checkpoints are
--                    recorded against the shop, and the shop is where trim
--                    quality lives (D5). PlacementIsArea = 1;
--                  - otherwise NULL (no unit above, no units in its area).
--                PlacementIsArea      1 when the placement is a ProductionArea
--                                     (counts on the area group, no unit tile).
--                ProductionAreaId     the ProductionArea at or above it.
--              Walks the location's own ancestor chain (a handful of seeks), so
--              it is cheap enough to apply per downtime / reject / LOT row.
--              Assumes units sit DIRECTLY under their ProductionArea, which is
--              the plant model (presses under DC1-4 / TRIM1-2, lines under MA1-2).
--              FILE NAME IS ORDER-SENSITIVE -- 'zz_' is a deploy-order marker,
--              kept so it deploys after Oee.ufn_OeeUnits it mirrors.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_AreaFamily (@LocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH Chain AS (
        SELECT l.Id, l.ParentLocationId, 0 AS Depth
        FROM Location.Location l
        WHERE l.Id = @LocationId
        UNION ALL
        SELECT p.Id, p.ParentLocationId, c.Depth + 1
        FROM Location.Location p
        INNER JOIN Chain c ON p.Id = c.ParentLocationId
    )
    SELECT
        CAST(COALESCE(
            CASE WHEN up.DefCode IS NULL THEN NULL WHEN up.DefCode = N'DieCastMachine' THEN N'diecast'
                 WHEN up.DefCode = N'TrimPress' THEN N'trim' ELSE N'ma' END,
            CASE WHEN au.DefCode IS NULL THEN NULL WHEN au.DefCode = N'DieCastMachine' THEN N'diecast'
                 WHEN au.DefCode = N'TrimPress' THEN N'trim' ELSE N'ma' END) AS NVARCHAR(10)) AS AreaFamily,
        CASE WHEN up.Id IS NOT NULL      THEN up.Id
             WHEN au.DefCode IS NOT NULL THEN ar.Id
        END                                               AS PlacementLocationId,
        CAST(CASE WHEN up.Id IS NULL AND au.DefCode IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT)               AS PlacementIsArea,
        ar.Id                                             AS ProductionAreaId
    FROM (SELECT 1 AS One) one
    OUTER APPLY (
        SELECT TOP 1 c.Id, d.Code AS DefCode
        FROM Chain c
        INNER JOIN Location.Location l               ON l.Id = c.Id
        INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
        WHERE l.IsOeeEnabled = 1 AND l.DeprecatedAt IS NULL
        ORDER BY c.Depth DESC
    ) up
    OUTER APPLY (
        SELECT TOP 1 c.Id
        FROM Chain c
        INNER JOIN Location.Location a                ON a.Id = c.Id
        INNER JOIN Location.LocationTypeDefinition ad ON ad.Id = a.LocationTypeDefinitionId
        WHERE ad.Code = N'ProductionArea'
        ORDER BY c.Depth ASC
    ) ar
    OUTER APPLY (
        SELECT TOP 1 d.Code AS DefCode
        FROM Location.Location u
        INNER JOIN Location.LocationTypeDefinition d ON d.Id = u.LocationTypeDefinitionId
        WHERE u.ParentLocationId = ar.Id
          AND u.IsOeeEnabled = 1 AND u.DeprecatedAt IS NULL
        ORDER BY u.Id
    ) au
);
GO
