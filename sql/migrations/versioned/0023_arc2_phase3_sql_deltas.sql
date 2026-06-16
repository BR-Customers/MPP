-- ============================================================
-- Migration:   0023_arc2_phase3_sql_deltas.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 3 SQL deltas (die-cast front-end dependencies).
--              Schema + seed only (the procs are repeatable migrations):
--                1. NEW code table Parts.DataCollectionFieldDataType (5 rows:
--                   String/Integer/Decimal/Boolean/Date) — a real FK code table
--                   for the typed-widget driver (DT-1: NOT the legacy
--                   Tools.ToolAttributeDefinition.DataType CHECK string).
--                2. Parts.DataCollectionField.DataTypeId BIGINT — added NULL,
--                   backfilled by Code, then ALTER NOT NULL + FK (DT-2: deliberate
--                   typing, not a silent NOT NULL DEFAULT).
--              Adds NO audit-lookup rows. Idempotent (re-apply = no-op).
--              ASCII-only seed strings (sqlcmd Windows-codepage guard).
-- ============================================================

-- ============================================================
-- == 1. Code table Parts.DataCollectionFieldDataType =========
-- ============================================================
IF OBJECT_ID(N'Parts.DataCollectionFieldDataType', N'U') IS NULL
    CREATE TABLE Parts.DataCollectionFieldDataType (
        Id           BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code         NVARCHAR(20)  NOT NULL,
        Name         NVARCHAR(50)  NOT NULL,
        Description  NVARCHAR(200) NULL,
        SortOrder    INT           NOT NULL DEFAULT 0,
        CreatedAt    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_DataCollectionFieldDataType_Code UNIQUE (Code)
    );
GO

-- ============================================================
-- == 2. Seed the 5 datatype rows (manual Id; idempotent) =====
-- ============================================================
SET IDENTITY_INSERT Parts.DataCollectionFieldDataType ON;
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 1 OR Code = N'String')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (1, N'String',  N'Text',           1);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 2 OR Code = N'Integer')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (2, N'Integer', N'Whole Number',   2);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 3 OR Code = N'Decimal')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (3, N'Decimal', N'Decimal Number', 3);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 4 OR Code = N'Boolean')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (4, N'Boolean', N'Yes / No',       4);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 5 OR Code = N'Date')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (5, N'Date',    N'Date',           5);
SET IDENTITY_INSERT Parts.DataCollectionFieldDataType OFF;
GO

-- ============================================================
-- == 3. Add the FK column NULL (temporarily) for backfill ====
-- ============================================================
IF COL_LENGTH(N'Parts.DataCollectionField', N'DataTypeId') IS NULL
    ALTER TABLE Parts.DataCollectionField ADD DataTypeId BIGINT NULL;
GO

-- ============================================================
-- == 4. Backfill the 7 shipped rows by Code (resolve FK Id) ==
-- ============================================================
UPDATE dcf
SET DataTypeId = dt.Id
FROM Parts.DataCollectionField dcf
INNER JOIN (VALUES
    (N'MaterialVerification', N'Boolean'),
    (N'SerialNumber',         N'String'),
    (N'DieInfo',              N'String'),
    (N'CavityInfo',           N'String'),
    (N'Weight',               N'Decimal'),
    (N'GoodCount',            N'Integer'),
    (N'BadCount',             N'Integer')
) AS m(FieldCode, TypeCode) ON m.FieldCode = dcf.Code
INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Code = m.TypeCode
WHERE dcf.DataTypeId IS NULL;
GO

-- ============================================================
-- == 5. Defensive: fail loudly if any row stayed untyped =====
-- ============================================================
IF EXISTS (SELECT 1 FROM Parts.DataCollectionField WHERE DataTypeId IS NULL)
    RAISERROR(N'0023 backfill incomplete: a Parts.DataCollectionField row has a NULL DataTypeId.', 16, 1);
GO

-- ============================================================
-- == 6. Lock the column NOT NULL + add the FK (guarded) ======
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Parts.DataCollectionField')
           AND name = N'DataTypeId' AND is_nullable = 1)
    ALTER TABLE Parts.DataCollectionField ALTER COLUMN DataTypeId BIGINT NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DataCollectionField_DataType')
    ALTER TABLE Parts.DataCollectionField
        ADD CONSTRAINT FK_DataCollectionField_DataType
            FOREIGN KEY (DataTypeId) REFERENCES Parts.DataCollectionFieldDataType(Id);
GO

-- ============================================================
-- == 7. Record migration =====================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0023_arc2_phase3_sql_deltas')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0023_arc2_phase3_sql_deltas',
            N'Arc 2 Phase 3 SQL deltas: Parts.DataCollectionFieldDataType code table (5 rows) + DataCollectionField.DataTypeId NOT NULL FK (backfilled). Procs (DataCollectionField_List v3.0, ProductionEvent_ListByLot, Lot_Create @LotName/@CavityNote) are repeatable. No audit-lookup rows.');
GO
PRINT 'Migration 0023 (Arc 2 Phase 3 SQL deltas) applied.';
GO
