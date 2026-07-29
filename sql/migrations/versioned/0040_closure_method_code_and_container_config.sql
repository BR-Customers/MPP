-- =============================================
-- Migration: 0040_closure_method_code_and_container_config.sql
-- Date: 2026-07-17
-- Desc: Closure method becomes the ContainerConfig discriminator.
--       (1) Parts.ClosureMethodCode code table (+seed).
--       (2) Backfill ContainerConfig.ClosureMethod NULL -> 'ByCount'.
--       (3) ClosureMethod NOT NULL + FK -> ClosureMethodCode.Code.
--       (4) Re-key active unique index (ItemId) -> (ItemId, ClosureMethod).
--       Idempotent-guarded; repo convention (no explicit outer transaction).
-- =============================================

IF OBJECT_ID(N'Parts.ClosureMethodCode') IS NULL
CREATE TABLE Parts.ClosureMethodCode (
    Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ClosureMethodCode PRIMARY KEY,
    Code         NVARCHAR(20)  NOT NULL CONSTRAINT UQ_ClosureMethodCode_Code UNIQUE,
    Name         NVARCHAR(50)  NOT NULL,
    SortOrder    INT           NOT NULL CONSTRAINT DF_ClosureMethodCode_SortOrder DEFAULT 0,
    DeprecatedAt DATETIME2(3)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM Parts.ClosureMethodCode)
BEGIN
    SET IDENTITY_INSERT Parts.ClosureMethodCode ON;
    INSERT INTO Parts.ClosureMethodCode (Id, Code, Name, SortOrder) VALUES
        (1, N'ByCount',  N'By Count',  1),
        (2, N'ByWeight', N'By Weight', 2),
        (3, N'ByVision', N'By Vision', 3);
    SET IDENTITY_INSERT Parts.ClosureMethodCode OFF;
END
GO

-- Backfill any NULL ClosureMethod before NOT NULL (default ByCount).
UPDATE Parts.ContainerConfig SET ClosureMethod = N'ByCount' WHERE ClosureMethod IS NULL;
GO

-- Drop the old (ItemId)-only active unique index.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_ActiveItemId')
    DROP INDEX UQ_ContainerConfig_ActiveItemId ON Parts.ContainerConfig;
GO

-- ClosureMethod NOT NULL.
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Parts.ContainerConfig')
           AND name = N'ClosureMethod' AND is_nullable = 1)
    ALTER TABLE Parts.ContainerConfig ALTER COLUMN ClosureMethod NVARCHAR(20) NOT NULL;
GO

-- FK ClosureMethod -> ClosureMethodCode.Code.
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ContainerConfig_ClosureMethod')
    ALTER TABLE Parts.ContainerConfig
        ADD CONSTRAINT FK_ContainerConfig_ClosureMethod
        FOREIGN KEY (ClosureMethod) REFERENCES Parts.ClosureMethodCode(Code);
GO

-- Re-keyed active unique index.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_ActiveItemMethod')
    CREATE UNIQUE INDEX UQ_ContainerConfig_ActiveItemMethod
        ON Parts.ContainerConfig (ItemId, ClosureMethod)
        WHERE DeprecatedAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0040_closure_method_code_and_container_config')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0040_closure_method_code_and_container_config',
        N'ClosureMethodCode code table; ContainerConfig.ClosureMethod NOT NULL + FK; re-key active unique index to (ItemId, ClosureMethod).');
GO
