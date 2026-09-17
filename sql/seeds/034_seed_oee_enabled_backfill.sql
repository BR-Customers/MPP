-- ============================================================
-- Seed:        034_seed_oee_enabled_backfill.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-17
-- Description: Sets Location.Location.IsOeeEnabled for a FRESH build.
--
--              Reset-DevDatabase runs versioned migrations, THEN repeatables,
--              THEN seeds -- so migration 0090's backfill runs against an
--              empty Location table and flags nothing. This applies the same
--              rule after 011_seed_locations_mpp_plant.sql has built the
--              plant. Mirror of 0090 section 2; keep the two in step.
--
--              Guarded on "nothing is flagged yet" so re-running the seeds
--              against a database where someone has since un-flagged a
--              location does not resurrect it.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE IsOeeEnabled = 1)
BEGIN
    ;WITH Tree AS (
        SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE l.ParentLocationId IS NULL
        UNION ALL
        SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
        FROM Location.Location c
        INNER JOIN Tree t                              ON c.ParentLocationId = t.Id
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    )
    UPDATE l
       SET l.IsOeeEnabled = 1
    FROM Location.Location l
    INNER JOIN Tree t                              ON t.Id   = l.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL
      AND l.IsOeeEnabled = 0
      AND lt.Code IN (N'WorkCenter', N'Cell')
      AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
      AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
    OPTION (MAXRECURSION 20);
END
GO

DECLARE @Flagged INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1);
PRINT 'Seed 034: OEE-enabled locations = ' + CAST(@Flagged AS NVARCHAR(10));
GO
