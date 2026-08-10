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
--   row).
--
--   Single-Published invariant is FORWARD-ONLY. The backfill deliberately
--   publishes ALL non-deprecated rows (not just the highest version per Code):
--   under the pre-lifecycle model CreateNewVersion left the parent un-deprecated,
--   so a Code could have several non-deprecated versions, and a RouteStep may pin
--   any of them via RouteStep.OperationTemplateId. Deprecating the older ones here
--   would make the route-role resolver (which also gates ot.DeprecatedAt IS NULL)
--   STOP resolving routes pinned to them -- a live-execution hazard. Publishing
--   them all keeps every currently-referenced template resolvable; the "at most
--   one Published-and-not-Deprecated per Code" invariant is enforced going forward
--   by OperationTemplate_Publish (set-based auto-deprecate of prior published rows).
--
--   Batch-guard note: RETURN aborts only the FIRST batch, so each GO-separated
--   batch below carries its own IF NOT EXISTS(SchemaVersion) guard. Without them a
--   manual/incremental re-apply would re-run the backfill (re-stamping Drafts
--   created after this migration first ran as Published) and throw a UNIQUE
--   violation on the SchemaVersion re-insert.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0053_operation_template_publish')
BEGIN PRINT 'Migration 0053 already applied -- skipping.'; RETURN; END
GO

-- Add PublishedAt (NULL = Draft). Guarded twice: SchemaVersion (re-apply) + COL_LENGTH.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0053_operation_template_publish')
   AND COL_LENGTH(N'Parts.OperationTemplate', N'PublishedAt') IS NULL
BEGIN
    ALTER TABLE Parts.OperationTemplate ADD PublishedAt DATETIME2(3) NULL;
END
GO

-- Backfill: every currently-live (non-deprecated) row becomes Published as-of its
-- CreatedAt (forward-only invariant -- see header note). SchemaVersion-guarded so a
-- re-apply never re-stamps Drafts created after this migration first ran.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0053_operation_template_publish')
BEGIN
    UPDATE Parts.OperationTemplate
    SET    PublishedAt = CreatedAt
    WHERE  DeprecatedAt IS NULL
      AND  PublishedAt  IS NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0053_operation_template_publish')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0053_operation_template_publish',
            N'Add Parts.OperationTemplate.PublishedAt (Draft/Published lifecycle); backfill non-deprecated rows to CreatedAt.');
GO
