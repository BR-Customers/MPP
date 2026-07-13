-- =============================================
-- Migration:   0033_operation_type_contract.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-02
-- Description: Operation-type model restructure (Spec 1 of 2) -- CONTRACT phase.
--              Runs after every consumer (seeds, procs, NQs, entity script) migrated
--              to OperationTypeId in the EXPAND window (0032).
--                * Enforces Parts.OperationTemplate.OperationTypeId NOT NULL.
--                * Drops Parts.OperationTemplate.AreaLocationId (FK + index + column).
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

-- Guard: every row must be mapped before enforcing NOT NULL.
IF EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE OperationTypeId IS NULL)
    RAISERROR(N'0033: OperationTemplate rows with NULL OperationTypeId remain -- cannot enforce NOT NULL.', 16, 1);
GO

-- Drop the OperationTypeId index so the column can be altered to NOT NULL, then recreate it.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationTemplate_OperationTypeId')
    DROP INDEX IX_OperationTemplate_OperationTypeId ON Parts.OperationTemplate;
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'OperationTypeId' AND is_nullable = 1)
    ALTER TABLE Parts.OperationTemplate ALTER COLUMN OperationTypeId BIGINT NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationTemplate_OperationTypeId')
    CREATE INDEX IX_OperationTemplate_OperationTypeId ON Parts.OperationTemplate(OperationTypeId);
GO

-- Drop the AreaLocationId FK (resolve its name dynamically), then its index, then the column.
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Parts.OperationTemplate') AND c.name = N'AreaLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Parts.OperationTemplate DROP CONSTRAINT ' + @fk);
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationTemplate_AreaLocationId')
    DROP INDEX IX_OperationTemplate_AreaLocationId ON Parts.OperationTemplate;
GO

IF COL_LENGTH(N'Parts.OperationTemplate', N'AreaLocationId') IS NOT NULL
    ALTER TABLE Parts.OperationTemplate DROP COLUMN AreaLocationId;
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0033_operation_type_contract')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0033_operation_type_contract',
        N'Operation-type restructure CONTRACT: OperationTemplate.OperationTypeId NOT NULL; drop AreaLocationId (FK + index + column).');
GO

PRINT 'Migration 0033 (operation_type_contract) applied.';
GO
