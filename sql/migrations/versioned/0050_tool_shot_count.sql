-- ============================================================
-- Migration:   0050_tool_shot_count.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: FAT #26/#27 - die (Tool) shot count. Adds a materialized
--              lifetime shot counter + optional lifetime shot limit to
--              Tools.Tool. ShotCount is incremented live by the die-cast
--              shift-output write proc (v1.2); ShotLimit is set via
--              Tools.Tool_Update. Derived remaining/percent/near/over live
--              in Tools.ufn_ShotStatus. No event ledger / reconcile job
--              (spec 2026-08-04-tool-shot-count-design.md, section 2).
-- ============================================================
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0050_tool_shot_count')
BEGIN
    PRINT 'Migration 0050 already applied - skipping.';
    COMMIT TRANSACTION;
    RETURN;
END

IF COL_LENGTH('Tools.Tool', 'ShotCount') IS NULL
    ALTER TABLE Tools.Tool ADD ShotCount INT NOT NULL DEFAULT 0 WITH VALUES;

IF COL_LENGTH('Tools.Tool', 'ShotLimit') IS NULL
    ALTER TABLE Tools.Tool ADD ShotLimit INT NULL;

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES ('0050_tool_shot_count',
        'FAT #26/#27: Tools.Tool + ShotCount INT NOT NULL DEFAULT 0 (materialized lifetime) + ShotLimit INT NULL. Live-incremented by DieCastShiftOutput_Record; derived fields via Tools.ufn_ShotStatus.');

COMMIT TRANSACTION;
PRINT 'Migration 0050 completed: Tools.Tool.ShotCount + ShotLimit.';
