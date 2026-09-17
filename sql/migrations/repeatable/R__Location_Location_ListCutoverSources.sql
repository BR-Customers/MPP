-- ============================================================
-- Repeatable:  R__Location_Location_ListCutoverSources.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
-- Description: The cutover scan's first pick -- where the stock being counted
--              is. The warehouse, the two trim stores, then every active
--              production line.
--
--              IsLine drives the screen: a line asks for an entry step and a
--              destination; a store IS the destination and the entry step is
--              not asked (castings in a store are waiting on Machining IN).
--
--              IsDefault marks the warehouse -- the screen opens on it.
--              Location IDs differ per environment, so the default is
--              resolved here, by Code, not written into the view.
--
--              Stores are the Location.IsCutoverDestination rows (0083).
--              Floor names for the trim stores are applied here (Trim Shop 1 =
--              Tumble, Trim Shop 2 = Blast); Location_ListCutoverDestinationsForLine
--              carries the SAME CASE -- change both. Lines are labelled
--              '<Code> - <Name>', as the line dropdown always was.
--
--              Lines are Location_ListProductionLines' set (WorkCenter tier,
--              ProductionLine definition), NOT Cell tier -- M&A stock is
--              line-resident.
--
--              Read proc: no OUTPUT params, one result set (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListCutoverSources
AS
BEGIN
    SET NOCOUNT ON;

    WITH lines AS (
        SELECT loc.Id, loc.Code, loc.Name
        FROM Location.Location loc
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = loc.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
        WHERE lt.Code  = N'WorkCenter'
          AND ltd.Code = N'ProductionLine'
          AND loc.DeprecatedAt IS NULL
    ),
    src AS (
        SELECT l.Id, l.Code, l.Name,
               CASE l.Code WHEN N'TRIM1-STORE' THEN N'Tumble Trim Storage'
                           WHEN N'TRIM2-STORE' THEN N'Blast Trim Storage'
                           ELSE l.Name END AS DisplayName,
               CAST(0 AS BIT) AS IsLine,
               CASE WHEN l.Code = N'WHSE' THEN 0 ELSE 1 END AS SortRank
        FROM Location.Location l
        WHERE l.IsCutoverDestination = 1
          AND l.DeprecatedAt IS NULL
          AND l.Id NOT IN (SELECT Id FROM lines)

        UNION ALL

        SELECT Id, Code, Name, Code + N' - ' + Name, CAST(1 AS BIT), 2
        FROM lines
    )
    SELECT
        Id,
        Code,
        Name,
        DisplayName,
        IsLine,
        CAST(CASE WHEN Code = N'WHSE' THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM src
    ORDER BY SortRank, CASE WHEN IsLine = 1 THEN Code ELSE DisplayName END;
END;
GO
