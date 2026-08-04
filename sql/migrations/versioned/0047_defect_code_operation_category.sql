-- ============================================================
-- Migration:   0047_defect_code_operation_category.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: Scope defect codes by process, not physical Area.
--              1. Add Quality.DefectCode.OperationCategoryId (nullable FK ->
--                 Parts.OperationCategory) + index.
--              2. Backfill from AreaLocationId by process family:
--                 DC1-4 -> DieCast, TRIM1/2 -> Trim, MA1/2 -> MachiningAssembly,
--                 site/other -> NULL (plant-wide). No-op on a fresh reset where
--                 DefectCode is empty (seed 030 runs later and inserts categories
--                 directly); matters only on an in-place upgrade.
--              3. Drop AreaLocationId (FK resolved dynamically + index + column).
--              NULL OperationCategoryId = plant-wide (applies everywhere).
--              Idempotent-guarded; no explicit transaction (repo convention).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0047_defect_code_operation_category')
BEGIN
    PRINT 'Migration 0047 already applied -- skipping.';
    RETURN;
END
GO

-- 1. Add nullable OperationCategoryId + FK
IF COL_LENGTH(N'Quality.DefectCode', N'OperationCategoryId') IS NULL
    ALTER TABLE Quality.DefectCode ADD OperationCategoryId BIGINT NULL
        CONSTRAINT FK_DefectCode_OperationCategory REFERENCES Parts.OperationCategory(Id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DefectCode_OperationCategoryId')
    CREATE INDEX IX_DefectCode_OperationCategoryId ON Quality.DefectCode (OperationCategoryId);
GO

-- 2. Backfill from AreaLocationId (only if the old column still exists -- guards re-run)
IF COL_LENGTH(N'Quality.DefectCode', N'AreaLocationId') IS NOT NULL
BEGIN
    DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
    DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
    DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');

    UPDATE dc
    SET OperationCategoryId =
        CASE
            WHEN loc.Code LIKE N'DC%'   THEN @DieCast
            WHEN loc.Code LIKE N'TRIM%' THEN @Trim
            WHEN loc.Code LIKE N'MA%'   THEN @MachAsm
            ELSE NULL   -- MPP-MAD / site-level / logistics -> plant-wide
        END
    FROM Quality.DefectCode dc
    LEFT JOIN Location.Location loc ON dc.AreaLocationId = loc.Id
    WHERE dc.OperationCategoryId IS NULL;
END
GO

-- 3. Drop AreaLocationId: FK (name resolved dynamically), index, column
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Quality.DefectCode') AND c.name = N'AreaLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Quality.DefectCode DROP CONSTRAINT ' + @fk);
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DefectCode_AreaLocationId')
    DROP INDEX IX_DefectCode_AreaLocationId ON Quality.DefectCode;
GO

IF COL_LENGTH(N'Quality.DefectCode', N'AreaLocationId') IS NOT NULL
    ALTER TABLE Quality.DefectCode DROP COLUMN AreaLocationId;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0047_defect_code_operation_category',
    N'Defect codes scoped by OperationCategory: add DefectCode.OperationCategoryId (nullable FK, plant-wide=NULL) + index, backfill from AreaLocationId by process family, drop AreaLocationId (FK + index + column).');
GO

PRINT 'Migration 0047 (defect_code_operation_category) applied.';
GO
