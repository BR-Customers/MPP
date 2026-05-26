-- ============================================================
-- Migration:   0015_parts_bom_unique_draft.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-05-26
-- Description: Filtered UNIQUE index on Parts.Bom(ParentItemId)
--              WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL.
--
--              Enforces one active Draft Bom per parent Item.
--              Multiple Published / Deprecated Bom rows for the same
--              parent may coexist (versioning) but only one Draft at
--              a time. The Item Master BOMs editor surface UI-gates
--              the "+ New Version" button on Draft count == 0 for
--              the parent; this filtered UNIQUE index is the DB-level
--              safety net against concurrent CreateNewVersion races.
--
--              Bom_CreateNewVersion / Bom_Create are responsible for
--              catching the resulting 2601/2627 violation and
--              returning Status=0 with a friendly message.
-- ============================================================

BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = '0015_parts_bom_unique_draft')
BEGIN
    PRINT 'Migration 0015 already applied -- skipping.';
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
    WHERE o.name = 'Bom'
      AND SCHEMA_NAME(o.schema_id) = 'Parts'
      AND i.name = 'UX_Bom_ActiveDraft'
)
BEGIN
    CREATE UNIQUE INDEX UX_Bom_ActiveDraft
        ON Parts.Bom (ParentItemId)
        WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL;
END

-- ============================================================
-- == Record migration ========================================
-- ============================================================
INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (
    '0015_parts_bom_unique_draft',
    'Filtered UNIQUE on Parts.Bom(ParentItemId) WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL. One active Draft per parent Item. Defends Bom_CreateNewVersion against concurrent draft creation.'
);

COMMIT TRANSACTION;
PRINT 'Migration 0015 completed: filtered UNIQUE index UX_Bom_ActiveDraft created on Parts.Bom.';
