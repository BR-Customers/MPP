-- =============================================
-- Migration:   0032_operation_type_expand.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-02
-- Description: Operation-type model restructure (Spec 1 of 2) -- EXPAND phase.
--                * Adds Parts.OperationCategory (3 seed) + Parts.OperationType (8 seed).
--                * Adds Parts.OperationTemplate.OperationTypeId (nullable, FK) + index.
--                * Relaxes Parts.OperationTemplate.AreaLocationId to NULL so seeds and
--                  procs can migrate off it during the transition.
--                * Backfills OperationTypeId for existing rows by Code (no-op on a fresh
--                  reset where OperationTemplate is empty at migration time; matters on an
--                  in-place upgrade).
--              The CONTRACT phase (0033) enforces OperationTypeId NOT NULL and drops
--              AreaLocationId once every consumer (seeds, procs, NQs, entity script) has
--              migrated. Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

-- 1. OperationCategory (read-only code table)
IF OBJECT_ID(N'Parts.OperationCategory') IS NULL
CREATE TABLE Parts.OperationCategory (
    Id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationCategory PRIMARY KEY,
    Code          NVARCHAR(20)  NOT NULL CONSTRAINT UQ_OperationCategory_Code UNIQUE,
    Name          NVARCHAR(100) NOT NULL,
    Description   NVARCHAR(500) NULL,
    CreatedAt     DATETIME2(3)  NOT NULL CONSTRAINT DF_OperationCategory_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeprecatedAt  DATETIME2(3)  NULL
);
GO

-- 2. OperationType (read-only role table)
IF OBJECT_ID(N'Parts.OperationType') IS NULL
CREATE TABLE Parts.OperationType (
    Id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationType PRIMARY KEY,
    Code                NVARCHAR(20)  NOT NULL CONSTRAINT UQ_OperationType_Code UNIQUE,
    Name                NVARCHAR(100) NOT NULL,
    OperationCategoryId BIGINT        NOT NULL CONSTRAINT FK_OperationType_Category
                                        REFERENCES Parts.OperationCategory(Id),
    Description         NVARCHAR(500) NULL,
    CreatedAt           DATETIME2(3)  NOT NULL CONSTRAINT DF_OperationType_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeprecatedAt        DATETIME2(3)  NULL
);
GO

-- 3. Seed categories
MERGE Parts.OperationCategory AS t
USING (VALUES
    (N'DieCast',            N'Die Cast'),
    (N'Trim',               N'Trim'),
    (N'MachiningAssembly',  N'Machining & Assembly')
) AS s(Code, Name) ON t.Code = s.Code
WHEN NOT MATCHED THEN INSERT (Code, Name) VALUES (s.Code, s.Name);
GO

-- 4. Seed types (category resolved by Code)
MERGE Parts.OperationType AS t
USING (VALUES
    (N'DieCast',      N'Die Cast',      N'DieCast'),
    (N'TrimIn',       N'Trim In',       N'Trim'),
    (N'TrimOut',      N'Trim Out',      N'Trim'),
    (N'MachiningIn',  N'Machining In',  N'MachiningAssembly'),
    (N'MachiningOut', N'Machining Out', N'MachiningAssembly'),
    (N'AssemblyIn',   N'Assembly In',   N'MachiningAssembly'),
    (N'AssemblyOut',  N'Assembly Out',  N'MachiningAssembly'),
    (N'CNC',          N'CNC',           N'MachiningAssembly')
) AS s(Code, Name, CategoryCode) ON t.Code = s.Code
WHEN NOT MATCHED THEN INSERT (Code, Name, OperationCategoryId)
    VALUES (s.Code, s.Name, (SELECT Id FROM Parts.OperationCategory WHERE Code = s.CategoryCode));
GO

-- 5. Add OperationTypeId (nullable during expand) + FK
IF COL_LENGTH(N'Parts.OperationTemplate', N'OperationTypeId') IS NULL
    ALTER TABLE Parts.OperationTemplate ADD OperationTypeId BIGINT NULL
        CONSTRAINT FK_OperationTemplate_OperationType REFERENCES Parts.OperationType(Id);
GO

-- 6. Supporting index
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationTemplate_OperationTypeId')
    CREATE INDEX IX_OperationTemplate_OperationTypeId ON Parts.OperationTemplate(OperationTypeId);
GO

-- 7. Relax AreaLocationId to nullable so seeds/procs can stop supplying it during migration
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'AreaLocationId' AND is_nullable = 0)
    ALTER TABLE Parts.OperationTemplate ALTER COLUMN AreaLocationId BIGINT NULL;
GO

-- 8. Backfill existing rows (confirmed template->role map, spec D3).
UPDATE ot SET OperationTypeId = (SELECT Id FROM Parts.OperationType WHERE Code = m.TypeCode)
FROM Parts.OperationTemplate ot
INNER JOIN (VALUES
    (N'DieCastShot',  N'DieCast'),
    (N'DC-5G0',       N'DieCast'),
    (N'TrimIn',       N'TrimIn'),
    (N'TrimOut',      N'TrimOut'),
    (N'TRIM-5G0',     N'TrimOut'),
    (N'MachiningIn',  N'MachiningIn'),
    (N'MachiningOut', N'MachiningOut'),
    (N'CNC-5G0',      N'CNC'),
    (N'ASSY-FRONT',   N'AssemblyOut')
) AS m(TemplateCode, TypeCode) ON m.TemplateCode = ot.Code
WHERE ot.OperationTypeId IS NULL;
GO

-- 9. Loud guard: any existing template left unmapped is a data error -- fail the migration.
IF EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE OperationTypeId IS NULL AND AreaLocationId IS NOT NULL)
    RAISERROR(N'0032: OperationTemplate rows exist with no OperationTypeId mapping -- extend the backfill map.', 16, 1);
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0032_operation_type_expand')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0032_operation_type_expand',
        N'Operation-type restructure EXPAND: add OperationCategory + OperationType, add OperationTemplate.OperationTypeId (nullable), relax AreaLocationId to NULL, backfill by Code.');
GO

PRINT 'Migration 0032 (operation_type_expand) applied.';
GO
