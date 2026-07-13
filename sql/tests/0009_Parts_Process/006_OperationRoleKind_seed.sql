-- Asserts the role-kind table + column seed/backfill (3 kinds per spec §4.1).
SET NOCOUNT ON;
IF (SELECT COUNT(*) FROM Parts.OperationRoleKind) <> 3 RAISERROR('Expected 3 OperationRoleKind rows.',16,1);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationRoleKind WHERE Code=N'Advance')     RAISERROR('Missing Advance kind.',16,1);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationRoleKind WHERE Code=N'OriginMint')  RAISERROR('Missing OriginMint kind.',16,1);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationRoleKind WHERE Code=N'ConsumeMint') RAISERROR('Missing ConsumeMint kind.',16,1);
IF EXISTS (SELECT 1 FROM Parts.OperationType WHERE OperationRoleKindId IS NULL) RAISERROR('OperationType.OperationRoleKindId has NULLs.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'DieCast')     <> N'OriginMint'  RAISERROR('DieCast must be OriginMint.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'MachiningIn') <> N'Advance'     RAISERROR('MachiningIn must be Advance.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'MachiningOut')<> N'ConsumeMint' RAISERROR('MachiningOut must be ConsumeMint.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'AssemblyOut') <> N'ConsumeMint' RAISERROR('AssemblyOut must be ConsumeMint.',16,1);
PRINT 'OperationRoleKind seed OK.';
