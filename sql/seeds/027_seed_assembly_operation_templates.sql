-- ============================================================
-- Seed:        027_seed_assembly_operation_templates.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-06
-- Description: Continuous Demo Seed Dataset (Task 1). The AssemblyIn +
--              AssemblyOut OperationTemplates the Assembly-line stations record
--              checkpoints against. NO OperationTemplateField children (serial
--              capture goes through the dedicated Lots.SerializedPart /
--              Lots.ContainerSerial tables introduced in Arc 2 Phase 6, not the
--              generic OperationTemplateField data-collection mechanism -- same
--              reasoning as Trim (024) and Machining (026), which also carry no
--              field children). TWO-state versioned entity (VersionNumber=1,
--              DeprecatedAt IS NULL = active). Idempotent on Code. ASCII-only.
--
--              Lives in a SEED (not a migration) for the same reason as
--              022/024/026: OperationTemplate no longer carries AreaLocationId
--              (dropped by migration 0033), so there is no seed-ordering
--              constraint against the plant hierarchy -- but the file is kept
--              in the same seed family for consistency and discoverability.
--
--              Dependency: migration 0032 (Parts.OperationType seeds
--              'AssemblyIn' / 'AssemblyOut', Category 'MachiningAssembly').
-- ============================================================
SET NOCOUNT ON;

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- Resolve the operation roles (migration 0032 seeds Parts.OperationType).
DECLARE @OpTypeAsmIn  BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'AssemblyIn'  AND DeprecatedAt IS NULL);
DECLARE @OpTypeAsmOut BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'AssemblyOut' AND DeprecatedAt IS NULL);

IF @OpTypeAsmIn IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'AssemblyIn')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, Description, CreatedAt)
    VALUES (N'AssemblyIn', 1, N'Assembly In', @OpTypeAsmIn,
            N'Assembly-line IN checkpoint template. FIFO pick of machined sub-assembly + BOM component consumption (mounting hardware, etc.) at the start of final assembly.',
            @Now);

IF @OpTypeAsmOut IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'AssemblyOut')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, Description, CreatedAt)
    VALUES (N'AssemblyOut', 1, N'Assembly Out', @OpTypeAsmOut,
            N'Assembly-line OUT template. Closing checkpoint for final assembly -- produces the finished-good LOT (serialized or non-serialized) ready for container packout.',
            @Now);
GO
PRINT 'Seed 027 (AssemblyIn/AssemblyOut OperationTemplates) loaded.';
GO
