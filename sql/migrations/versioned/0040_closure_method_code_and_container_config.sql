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
