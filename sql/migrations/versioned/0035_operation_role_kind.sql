-- =============================================
-- Migration:   0035_operation_role_kind.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-07
-- Description: Terminal-mint model (spec 2026-07-07) §4.1 — add the operation
--              role-kind classification: Advance / OriginMint / ConsumeMint.
--              The queue rule (§3.2) needs the origin-vs-consume distinction:
--                * ConsumeMint (Machining/Assembly OUT) = terminal step; keeps a
--                  LOT in that terminal's queue until it is fully consumed (closed).
--                * OriginMint  (Die Cast) = produces this part; always satisfied.
--                * Advance     = satisfied by a matching ProductionEvent.
--              Adds Parts.OperationRoleKind (3 seed) + a NOT NULL FK on
--              Parts.OperationType, backfilled per the §4.1 mapping.
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF OBJECT_ID(N'Parts.OperationRoleKind') IS NULL
CREATE TABLE Parts.OperationRoleKind (
    Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationRoleKind PRIMARY KEY,
    Code         NVARCHAR(20)  NOT NULL CONSTRAINT UQ_OperationRoleKind_Code UNIQUE,
    Name         NVARCHAR(100) NOT NULL,
    Description  NVARCHAR(500) NULL,
    CreatedAt    DATETIME2(3)  NOT NULL CONSTRAINT DF_OperationRoleKind_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeprecatedAt DATETIME2(3)  NULL
);
GO

MERGE Parts.OperationRoleKind AS t
USING (VALUES
    (N'Advance',     N'Advance'),
    (N'OriginMint',  N'Origin Mint'),
    (N'ConsumeMint', N'Consume Mint')
) AS s(Code, Name) ON t.Code = s.Code
WHEN NOT MATCHED THEN INSERT (Code, Name) VALUES (s.Code, s.Name);
GO

IF COL_LENGTH(N'Parts.OperationType', N'OperationRoleKindId') IS NULL
    ALTER TABLE Parts.OperationType ADD OperationRoleKindId BIGINT NULL
        CONSTRAINT FK_OperationType_RoleKind REFERENCES Parts.OperationRoleKind(Id);
GO

-- Backfill per §4.1: DieCast = OriginMint; MachiningOut/AssemblyOut = ConsumeMint; else Advance.
UPDATE t SET OperationRoleKindId = (SELECT Id FROM Parts.OperationRoleKind WHERE Code =
    CASE WHEN t.Code = N'DieCast' THEN N'OriginMint'
         WHEN t.Code IN (N'MachiningOut', N'AssemblyOut') THEN N'ConsumeMint'
         ELSE N'Advance' END)
FROM Parts.OperationType t WHERE t.OperationRoleKindId IS NULL;
GO

IF EXISTS (SELECT 1 FROM Parts.OperationType WHERE OperationRoleKindId IS NULL)
    RAISERROR(N'0035: OperationType rows unmapped to a role-kind.', 16, 1);
GO

ALTER TABLE Parts.OperationType ALTER COLUMN OperationRoleKindId BIGINT NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0035_operation_role_kind')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0035_operation_role_kind',
        N'Add Parts.OperationRoleKind (Advance/OriginMint/ConsumeMint) + OperationType.OperationRoleKindId (NOT NULL, backfilled).');
GO

PRINT 'Migration 0035 (operation_role_kind) applied.';
GO
