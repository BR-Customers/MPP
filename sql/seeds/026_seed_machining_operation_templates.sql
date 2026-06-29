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

-- Resolve the Machining Area. Prefer the canonical 'MA1' area (011 seed); fall
-- back to the first active Area-tier Location so a partial location seed still
-- satisfies the FK.
DECLARE @MachAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1' AND DeprecatedAt IS NULL);
IF @MachAreaId IS NULL
    SET @MachAreaId = (
        SELECT TOP 1 l.Id
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
        WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area'
        ORDER BY l.Id);

IF @MachAreaId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'MachiningIn')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, RequiresSubLotSplit, CreatedAt)
    VALUES (N'MachiningIn', 1, N'Machining In', @MachAreaId,
            N'Machining-line IN checkpoint template (Arc 2 Phase 5). FIFO pick of a whole cast/trim LOT + BOM-driven part-identity rename (FDS-05-033); written by MachiningIn_PickAndConsume.',
            0, @Now);

IF @MachAreaId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'MachiningOut')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, RequiresSubLotSplit, CreatedAt)
    VALUES (N'MachiningOut', 1, N'Machining Out', @MachAreaId,
            N'Machining-line OUT template (Arc 2 Phase 5). Closing checkpoint for either the operator sub-LOT split (RequiresSubLotSplit=1, FDS-05-009) or the PLC auto-complete/auto-move (FDS-06-008).',
            1, @Now);
GO
PRINT 'Seed 026 (MachiningIn/MachiningOut OperationTemplates) loaded.';
GO
