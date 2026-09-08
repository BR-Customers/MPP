-- =============================================
-- Migration:   0071_insp_sort_terminal_default_screen.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-08
-- Description: Point the Sort Cage inspection terminal (INSP-SORT-T1) at the Sort
--              Cage screen instead of Third Party Inspection.
--
--              The seed already carries the new value -- sql/seeds/gen_locations_mpp.js
--              gained a SORTCAGE role and both generated outputs
--              (011_seed_locations_mpp_plant.sql and scripts/reconcile_location_dev.sql)
--              emit '/shop-floor/sort-cage'. But the seed's INSERT is wrapped in an
--              IF NOT EXISTS that tests for the PRESENCE of the LocationAttribute row,
--              not its value. Every database that was seeded before that change already
--              has the row, so re-running seeds is a no-op there and the terminal keeps
--              opening Third Party Inspection. Dev and Prod are both in that state.
--
--              Hence this migration: fresh builds get the value from the seed, existing
--              databases get it from here.
--
--              Guarded on the OLD value, so it is idempotent and will not clobber a
--              terminal an admin has deliberately pointed somewhere else. UpdatedByUserId
--              is left NULL -- this is a system change with no AppUser behind it.
--
--              Idempotent. Guarded per statement -- a top-of-file RETURN would only
--              exit its own batch.
-- =============================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0071_insp_sort_terminal_default_screen')
    PRINT 'Migration 0071 already applied -- statements below are individually guarded.';
GO

-- ---- 1. Retarget INSP-SORT-T1's DefaultScreen ----
UPDATE la
SET    la.AttributeValue = N'/shop-floor/sort-cage',
       la.UpdatedAt      = SYSUTCDATETIME()
FROM   Location.LocationAttribute la
JOIN   Location.Location l
       ON l.Id = la.LocationId
JOIN   Location.LocationAttributeDefinition ad
       ON ad.Id = la.LocationAttributeDefinitionId
WHERE  l.Code = N'INSP-SORT-T1'
  AND  ad.AttributeName = N'DefaultScreen'
  AND  ad.LocationTypeDefinitionId = 7
  AND  la.AttributeValue = N'/shop-floor/third-party-inspection';
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
SELECT N'0071_insp_sort_terminal_default_screen',
       N'INSP-SORT-T1 (Sort Cage inspection terminal) DefaultScreen retargeted from /shop-floor/third-party-inspection to /shop-floor/sort-cage. Seeds already emit the new value but their IF NOT EXISTS guard is presence-only, so already-seeded databases needed this.'
WHERE NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0071_insp_sort_terminal_default_screen');
GO

PRINT 'Migration 0071 (INSP-SORT-T1 default screen) applied.';
GO
