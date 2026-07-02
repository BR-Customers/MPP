-- ============================================================
-- Seed:        026_seed_machining_operation_templates.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-19
-- Description: Arc 2 Phase 5 (Machining). The MachiningIn + MachiningOut
--              OperationTemplates the Machining-line stations record checkpoints
--              against. NO OperationTemplateField children (Machining uses the
--              promoted ProductionEvent ShotCount/ScrapCount columns only, like
--              Trim). TWO-state versioned entity (VersionNumber=1, DeprecatedAt
--              IS NULL = active). Idempotent on Code.
--
--              RequiresSubLotSplit (migration 0027 ALTER):
--                * MachiningIn  -> 0 (no outbound split at IN; IN is the FIFO
--                                    pick + BOM rename, not a split).
--                * MachiningOut -> 1 (the initial sublotting default per the
--                                    Phased Plan: lines known to sublot present
--                                    the operator multi-destination split screen;
--                                    Engineering clones-to-modify per Item/Cell to
--                                    flip a line to the PLC auto-move path = 0).
--
--              Lives in a SEED (not migration 0027) because
--              OperationTemplate.AreaLocationId is a NOT NULL FK to the
--              seed-loaded plant hierarchy (011) which is applied AFTER all
--              migrations. ASCII-only. Dependencies: 011 (Machining Area, MA1) +
--              migration 0027 (RequiresSubLotSplit column).
-- ============================================================
SET NOCOUNT ON;

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- Resolve the operation roles (migration 0032 seeds Parts.OperationType).
DECLARE @OpTypeMachIn  BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'MachiningIn'  AND DeprecatedAt IS NULL);
DECLARE @OpTypeMachOut BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'MachiningOut' AND DeprecatedAt IS NULL);

IF @OpTypeMachIn IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'MachiningIn')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, Description, RequiresSubLotSplit, CreatedAt)
    VALUES (N'MachiningIn', 1, N'Machining In', @OpTypeMachIn,
            N'Machining-line IN checkpoint template (Arc 2 Phase 5). FIFO pick of a whole cast/trim LOT + BOM-driven part-identity rename (FDS-05-033); written by MachiningIn_PickAndConsume.',
            0, @Now);

IF @OpTypeMachOut IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'MachiningOut')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, Description, RequiresSubLotSplit, CreatedAt)
    VALUES (N'MachiningOut', 1, N'Machining Out', @OpTypeMachOut,
            N'Machining-line OUT template (Arc 2 Phase 5). Closing checkpoint for either the operator sub-LOT split (RequiresSubLotSplit=1, FDS-05-009) or the PLC auto-complete/auto-move (FDS-06-008).',
            1, @Now);
GO
PRINT 'Seed 026 (MachiningIn/MachiningOut OperationTemplates) loaded.';
GO
