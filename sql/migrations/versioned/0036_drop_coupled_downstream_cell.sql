-- =============================================
-- Migration:   0036_drop_coupled_downstream_cell.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-07
-- Description: Terminal-mint model (spec 2026-07-07) §3.8/§5 B7 — retire the
--              cell-resident auto-couple path. Mints are line-resident; there is
--              no cell->cell auto-move, so Location.CoupledDownstreamCellLocationId
--              and Workorder.MachiningOut_AutoComplete are dead. Drop the FK +
--              column + proc. The unused MachiningOutAutoMoved audit event row is
--              left in place (LogEventType has no DeprecatedAt; harmless).
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

-- Drop the FK on CoupledDownstreamCellLocationId (resolve name dynamically), then the column.
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Location.Location') AND c.name = N'CoupledDownstreamCellLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Location.Location DROP CONSTRAINT ' + @fk);
GO

IF COL_LENGTH(N'Location.Location', N'CoupledDownstreamCellLocationId') IS NOT NULL
    ALTER TABLE Location.Location DROP COLUMN CoupledDownstreamCellLocationId;
GO

IF OBJECT_ID(N'Workorder.MachiningOut_AutoComplete') IS NOT NULL
    DROP PROCEDURE Workorder.MachiningOut_AutoComplete;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0036_drop_coupled_downstream_cell')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0036_drop_coupled_downstream_cell',
        N'Retire cell-coupling: drop Location.CoupledDownstreamCellLocationId (+FK) and Workorder.MachiningOut_AutoComplete.');
GO

PRINT 'Migration 0036 (drop_coupled_downstream_cell) applied.';
GO
