-- ============================================================
-- Migration: 0053_operation_template_publish.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-07
-- Description: Retrofit the Draft/Published/Deprecated lifecycle onto
--   Parts.OperationTemplate (FAT-OQ-030), mirroring the RouteTemplate/Bom
--   PublishedAt pattern from 0007_bom_and_route_publish.sql.
--
--   Adds Parts.OperationTemplate.PublishedAt (NULL = Draft, set = Published)
--   and backfills every existing non-deprecated row to PublishedAt = CreatedAt
--   so routes that already resolve OperationTemplates keep resolving after the
--   Publish gate lands on the resolver. Deprecated rows are left PublishedAt
--   NULL (they never resolve; no publish timestamp is fabricated for a retired
--   row). Idempotent-guarded.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0053_operation_template_publish')
BEGIN PRINT 'Migration 0053 already applied -- skipping.'; RETURN; END
GO

-- Add PublishedAt (NULL = Draft). Guarded so a re-run is a no-op.
IF COL_LENGTH(N'Parts.OperationTemplate', N'PublishedAt') IS NULL
BEGIN
    ALTER TABLE Parts.OperationTemplate ADD PublishedAt DATETIME2(3) NULL;
END
GO

-- Backfill: every currently-live (non-deprecated) row becomes Published as-of
-- its CreatedAt, so existing routes keep resolving once the resolver gates on
-- PublishedAt IS NOT NULL. Only touches rows still NULL (idempotent re-run safe).
UPDATE Parts.OperationTemplate
SET    PublishedAt = CreatedAt
WHERE  DeprecatedAt IS NULL
  AND  PublishedAt  IS NULL;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0053_operation_template_publish',
        N'Add Parts.OperationTemplate.PublishedAt (Draft/Published lifecycle); backfill non-deprecated rows to CreatedAt.');
GO
