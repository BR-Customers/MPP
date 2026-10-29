-- =============================================
-- Repeatable:  R__Oee_ufn_OeeUnits.sql
-- Object:      Oee.ufn_OeeUnits
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: Every active OEE-enabled location, classified for the OEE
--              dashboard (spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.2):
--                IsStation = 0  a UNIT: no OEE-enabled ancestor (a press, a
--                               trim press, a line).
--                IsStation = 1  a station under a unit (contributes downtime
--                               only, D3); ParentUnitLocationId is its nearest
--                               flagged ancestor, TopUnitLocationId the unit.
--                AreaFamily     from the TOP unit's definition: DieCastMachine
--                               -> diecast, TrimPress -> trim, anything else ->
--                               ma. M&A is the catch-all: inspection and
--                               offsite lines sit under M&A (Jacques, 2026-10-29).
--                ProductionArea the ProductionArea ancestor (Die Cast 1-4,
--                               Trim Shop 1-2, M&A 1-2, ...).
--              Same flag + deprecation rule as Oee.ufn_ResolveOeeEquipment.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_OeeUnits ()
RETURNS TABLE
AS
RETURN
(
    SELECT
        l.Id                                         AS LocationId,
        l.Code,
        l.Name,
        d.Code                                       AS DefinitionCode,
        l.SortOrder,
        CAST(CASE WHEN pa.AncestorLocationId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsStation,
        pa.AncestorLocationId                        AS ParentUnitLocationId,
        COALESCE(tp.AncestorLocationId, l.Id)        AS TopUnitLocationId,
        CAST(CASE COALESCE(td.Code, d.Code)
                 WHEN N'DieCastMachine' THEN N'diecast'
                 WHEN N'TrimPress'      THEN N'trim'
                 ELSE N'ma' END AS NVARCHAR(10))     AS AreaFamily,
        ar.Id                                        AS ProductionAreaId,
        ar.Name                                      AS ProductionAreaName,
        ar.SortOrder                                 AS ProductionAreaSortOrder
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    OUTER APPLY (SELECT TOP 1 a.AncestorLocationId FROM Oee.ufn_OeeAncestors(l.Id) a ORDER BY a.Distance ASC)  pa
    OUTER APPLY (SELECT TOP 1 a.AncestorLocationId FROM Oee.ufn_OeeAncestors(l.Id) a ORDER BY a.Distance DESC) tp
    LEFT  JOIN Location.Location tl               ON tl.Id = tp.AncestorLocationId
    LEFT  JOIN Location.LocationTypeDefinition td ON td.Id = tl.LocationTypeDefinitionId
    OUTER APPLY (
        SELECT TOP 1 a.Id, a.Name, a.SortOrder
        FROM Location.ufn_AncestorLocationIds(l.Id) x
        INNER JOIN Location.Location a                ON a.Id = x.LocationId
        INNER JOIN Location.LocationTypeDefinition ad ON ad.Id = a.LocationTypeDefinitionId
        WHERE ad.Code = N'ProductionArea'
    ) ar
    WHERE l.DeprecatedAt IS NULL
      AND l.IsOeeEnabled = 1
);
GO
