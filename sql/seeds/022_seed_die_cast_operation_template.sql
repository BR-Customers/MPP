-- ============================================================
-- Seed:        022_seed_die_cast_operation_template.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-15
-- Description: Arc 2 Phase 3 (§3). The DieCastShot OperationTemplate the die-cast
--              operator station records production checkpoints against, plus its
--              OperationTemplateField children.
--
--              Lives in a SEED (not migration 0022) because
--              Parts.OperationTemplate.AreaLocationId is a NOT NULL FK to
--              Location.Location and the plant hierarchy is itself seeded
--              (011_seed_locations_mpp_plant.sql) AFTER all migrations run. This
--              seed runs after 011 (locations) + 0004 migration (DataCollection
--              field code table) so both FK targets exist.
--
--              OperationTemplate is a TWO-state versioned entity (VersionNumber +
--              CreatedAt + DeprecatedAt; NO PublishedAt column — verified against
--              migration 0006). An active row (DeprecatedAt IS NULL) is the
--              published/usable state. Seeded at VersionNumber=1.
--
--              Idempotent (IF NOT EXISTS on Code). ASCII-only.
--              Dependencies: 011_seed_locations_mpp_plant.sql (Area Code 'DC1').
-- ============================================================

SET NOCOUNT ON;

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- Resolve the die-cast Area. Prefer the canonical 'DC1' area (011 seed); fall
-- back to the first active Area-tier Location so a partial location seed still
-- satisfies the FK.
DECLARE @AreaLocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1' AND DeprecatedAt IS NULL);
IF @AreaLocId IS NULL
    SET @AreaLocId = (
        SELECT TOP 1 l.Id
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
        WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area'
        ORDER BY l.Id);

IF @AreaLocId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'DieCastShot')
BEGIN
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (N'DieCastShot', 1, N'Die Cast Shot', @AreaLocId,
            N'Die-cast operator-station production checkpoint template (Arc 2 Phase 3). Captures cumulative shot/scrap counters plus per-shot data-collection fields.',
            @Now);

    DECLARE @OtId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    -- Attach the data-collection fields a checkpoint captures (bind by Code to the
    -- 0004 DataCollectionField seeds). Only fields that resolve are attached; the
    -- filtered unique index on (OperationTemplateId, DataCollectionFieldId) keeps
    -- pairings unique among active rows.
    INSERT INTO Parts.OperationTemplateField (OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt)
    SELECT @OtId, dcf.Id, 0, @Now
    FROM Parts.DataCollectionField dcf
    WHERE dcf.DeprecatedAt IS NULL
      AND dcf.Code IN (N'DieInfo', N'CavityInfo', N'Weight', N'GoodCount', N'BadCount')
      AND NOT EXISTS (
          SELECT 1 FROM Parts.OperationTemplateField otf
          WHERE otf.OperationTemplateId = @OtId
            AND otf.DataCollectionFieldId = dcf.Id
            AND otf.DeprecatedAt IS NULL);
END
GO

PRINT 'Seed 022 (DieCastShot OperationTemplate + fields) loaded.';
GO
