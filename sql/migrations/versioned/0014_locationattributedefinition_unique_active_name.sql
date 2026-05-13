-- ============================================================
-- Migration:   0014_locationattributedefinition_unique_active_name.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-05-13
-- Description: Adds a filtered UNIQUE index on
--              Location.LocationAttributeDefinition
--              (LocationTypeDefinitionId, AttributeName)
--              WHERE DeprecatedAt IS NULL.
--
--              Defends the new LocationTypeDefinition_SaveAll bundled
--              save proc against duplicate active attribute names
--              within a definition. Deprecated names remain
--              unconstrained, so a name can be reused after a
--              soft-delete cycle without manual cleanup.
--
--              Pre-flight (2026-05-13): zero collisions in the
--              current 16 active seed rows; index applies clean.
-- ============================================================

BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = '0014_locationattributedefinition_unique_active_name')
BEGIN
    PRINT 'Migration 0014 already applied -- skipping.';
    COMMIT;
    RETURN;
END

-- ============================================================
-- == Filtered UNIQUE index ===================================
-- ============================================================
-- Guarded by sys.indexes lookup so manual re-runs stay safe even if
-- the SchemaVersion row is wiped externally.

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes i
    JOIN sys.objects o ON o.object_id = i.object_id
    WHERE o.name = 'LocationAttributeDefinition'
      AND SCHEMA_NAME(o.schema_id) = 'Location'
      AND i.name = 'UX_LocationAttributeDefinition_ActiveName'
)
BEGIN
    CREATE UNIQUE INDEX UX_LocationAttributeDefinition_ActiveName
        ON Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName)
        WHERE DeprecatedAt IS NULL;
END

-- ============================================================
-- == Record migration ========================================
-- ============================================================
INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (
    '0014_locationattributedefinition_unique_active_name',
    'Filtered UNIQUE on Location.LocationAttributeDefinition(LocationTypeDefinitionId, AttributeName) WHERE DeprecatedAt IS NULL. Defends LocationTypeDefinition_SaveAll bundled-save proc against active-name collisions; allows deprecated-name reuse.'
);

COMMIT TRANSACTION;
PRINT 'Migration 0014 completed: filtered UNIQUE index UX_LocationAttributeDefinition_ActiveName created.';
