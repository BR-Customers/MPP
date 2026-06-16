-- ============================================================
-- Seed:        024_seed_trim_operation_templates.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 4. The TrimIn + TrimOut OperationTemplates that the
--              Trim Station records checkpoints against. NO OperationTemplateField
--              children (Confirm C: Trim uses the promoted ProductionEvent
--              ShotCount/ScrapCount columns only). TWO-state versioned entity
--              (VersionNumber=1, DeprecatedAt IS NULL = active). Idempotent on Code.
--              Lives in a SEED (not migration 0024) because
--              OperationTemplate.AreaLocationId NOT NULL FKs the seed-loaded plant
--              hierarchy (011). ASCII-only. Dependency: 011 (Trim Shop 1 Area, TRIM1).
-- ============================================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

DECLARE @TrimAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1' AND DeprecatedAt IS NULL);
IF @TrimAreaId IS NULL
    SET @TrimAreaId = (
        SELECT TOP 1 l.Id
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
        WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area'
        ORDER BY l.Id);

IF @TrimAreaId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'TrimIn')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (N'TrimIn', 1, N'Trim In', @TrimAreaId,
            N'Trim-station IN checkpoint template (Arc 2 Phase 4). Carried-forward cumulative shot/scrap counters; yield-loss only, no rename.', @Now);

IF @TrimAreaId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'TrimOut')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (N'TrimOut', 1, N'Trim Out', @TrimAreaId,
            N'Trim-station OUT template (Arc 2 Phase 4). Closing checkpoint for a 1:1 whole-LOT move into a Machining-line FIFO queue.', @Now);
GO
PRINT 'Seed 024 (Trim IN/OUT OperationTemplates) loaded.';
GO
