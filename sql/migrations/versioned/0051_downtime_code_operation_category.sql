-- ============================================================
-- Migration: 0051_downtime_code_operation_category.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-05
-- Description: Scope downtime reason codes by process, not physical Area (FAT #3;
--   mirror of 0048). Add Oee.DowntimeReasonCode.OperationCategoryId (nullable FK ->
--   Parts.OperationCategory) + index; backfill from AreaLocationId by process family
--   (DC%->DieCast, TRIM%->Trim, MA%->MachiningAssembly, else NULL=plant-wide);
--   drop AreaLocationId (FK resolved dynamically + index + column). Idempotent-guarded.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0051_downtime_code_operation_category')
BEGIN PRINT 'Migration 0051 already applied -- skipping.'; RETURN; END
GO

IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'OperationCategoryId') IS NULL
    ALTER TABLE Oee.DowntimeReasonCode ADD OperationCategoryId BIGINT NULL
        CONSTRAINT FK_DowntimeReasonCode_OperationCategory REFERENCES Parts.OperationCategory(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DowntimeReasonCode_OperationCategoryId')
    CREATE INDEX IX_DowntimeReasonCode_OperationCategoryId ON Oee.DowntimeReasonCode (OperationCategoryId);
GO

-- Backfill from AreaLocationId by process family (only while the old column exists).
IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'AreaLocationId') IS NOT NULL
BEGIN
    DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
    DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
    DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');
    UPDATE drc
    SET OperationCategoryId =
        CASE WHEN loc.Code LIKE N'DC%'   THEN @DieCast
             WHEN loc.Code LIKE N'TRIM%' THEN @Trim
             WHEN loc.Code LIKE N'MA%'   THEN @MachAsm
             ELSE NULL END   -- site-level / Break / logistics -> plant-wide
    FROM Oee.DowntimeReasonCode drc
    LEFT JOIN Location.Location loc ON drc.AreaLocationId = loc.Id
    WHERE drc.OperationCategoryId IS NULL;
END
GO

-- Drop AreaLocationId: FK (name resolved dynamically), index, column.
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Oee.DowntimeReasonCode') AND c.name = N'AreaLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Oee.DowntimeReasonCode DROP CONSTRAINT ' + @fk);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DowntimeReasonCode_AreaLocationId')
    DROP INDEX IX_DowntimeReasonCode_AreaLocationId ON Oee.DowntimeReasonCode;
GO
IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'AreaLocationId') IS NOT NULL
    ALTER TABLE Oee.DowntimeReasonCode DROP COLUMN AreaLocationId;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0051_downtime_code_operation_category', N'Oee.DowntimeReasonCode scoped by OperationCategory (nullable FK, plant-wide=NULL) + index; backfill by process family; drop AreaLocationId.');
GO
PRINT 'Migration 0051 (downtime_code_operation_category) applied.';
GO
