-- ============================================================
-- Migration:   0090_location_is_oee_enabled.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-17
-- Description: Location.Location.IsOeeEnabled -- "is this location a downtime
--              and OEE unit?" -- the opt-in flag that replaces the implicit
--              self-scoping rule in Oee.ufn_ResolveDowntimeScope /
--              Oee.ufn_ResolveOeeEquipment.
--
--              WHY. Downtime resolves UP to the nearest WorkCenter, so a cell
--              under a Machining & Assembly line can never be a downtime unit.
--              6MA Cam Holder Line 1 needs three units under the line
--              (Machining, Assembly A, Assembly B) plus the line itself, and
--              the location model must not be restructured to get them.
--              Spec: docs/superpowers/specs/2026-09-16-oee-enabled-locations-
--              and-rollup-design.md.
--
--              ON THE INSTANCE, NOT THE TYPE. Unlike IsStockLocation (0081),
--              which answers a question about a KIND of location, this is
--              per-location opt-in: two Assembly Stations on different lines
--              may differ.
--
--              BACKFILL. Flags exactly what the pre-change rule admitted, so
--              day one is a no-op: every active die cast / trim machine and
--              every line stays a downtime unit and every dropdown is
--              unchanged. The rule is INLINED rather than calling
--              Oee.ufn_ResolveOeeEquipment because Reset-DevDatabase runs
--              versioned migrations BEFORE repeatables -- the function does
--              not exist yet on a fresh build. On a fresh build the backfill
--              also matches nothing (locations are seeded afterwards), which
--              is why sql/seeds/034_seed_oee_enabled_backfill.sql repeats it.
--
--              Scale is excluded here although the old rule admitted it: a
--              bench scale is not equipment a shift runs on. No Scale row
--              exists under any Area in prod (2026-09-17 extract), so this
--              changes nothing today.
--
--              Idempotent-guarded; the backfill carries its OWN guard because
--              a batch-level RETURN only exits the first batch, and re-running
--              the backfill would re-flag a location an operator had turned
--              off. ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0090_location_is_oee_enabled')
BEGIN PRINT 'Migration 0090 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. The column ----
IF COL_LENGTH('Location.Location', 'IsOeeEnabled') IS NULL
    ALTER TABLE Location.Location
        ADD IsOeeEnabled BIT NOT NULL
            CONSTRAINT DF_Location_IsOeeEnabled DEFAULT 0;
GO

-- ---- 2. Backfill from the pre-change rule (first application only) ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0090_location_is_oee_enabled')
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

-- ---- 3. Report, so a surprising flag set is visible at deploy time ----
DECLARE @Flagged INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1);
PRINT 'OEE-enabled locations after backfill: ' + CAST(@Flagged AS NVARCHAR(10));

DECLARE @Nested NVARCHAR(500) = (
    SELECT STUFF((SELECT N', ' + p.Code
                  FROM Location.Location p
                  WHERE p.IsOeeEnabled = 1 AND p.DeprecatedAt IS NULL
                    AND EXISTS (SELECT 1 FROM Location.Location c
                                WHERE c.ParentLocationId = p.Id
                                  AND c.IsOeeEnabled = 1 AND c.DeprecatedAt IS NULL)
                  ORDER BY p.Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''));
PRINT 'Flagged locations that already have a flagged child (become roll-ups): ' + ISNULL(@Nested, N'(none)');
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0090_location_is_oee_enabled')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0090_location_is_oee_enabled',
            N'Location.Location.IsOeeEnabled (BIT, default 0) + backfill from the pre-change self-scoping equipment rule. The flag is now the definition of a downtime / OEE unit, so a cell under a production line can be one (6MA Machining / Assembly A / Assembly B).');
GO
PRINT 'Migration 0090 (location_is_oee_enabled) applied.';
GO
