-- =============================================
-- Migration: 0018_tooltype_compatible_celldef
-- Adds Tools.ToolType.CompatibleLocationTypeDefinitionId -> a nullable FK to
-- Location.LocationTypeDefinition. This is the one-to-one mapping that lets the
-- Mount-to-Cell dropdown filter Cell-tier Locations down to the kind a given
-- tool type can actually mount on (a Die Cast Die only lists Die Cast Machine
-- cells, not CNC machines / terminals / scales).
--
-- Mapping semantics:
--   * NON-NULL -> the dropdown shows only Cells whose LocationTypeDefinitionId
--                 matches this value.
--   * NULL     -> no restriction; the dropdown shows all Cell-tier Locations.
--                 Tool types other than Die are left NULL until their flows
--                 activate, so they stay unfiltered (non-blocking).
--
-- Seed: Die -> DieCastMachine. Resolved by Code (robust to identity drift)
-- rather than hard-coding LocationTypeDefinition.Id = 8.
--
-- Note: the compatibility rule is consumed by Tools.Tool_ListCompatibleCells
-- (repeatable). The column carries the data; the proc enforces the filter.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID(N'Tools.ToolType')
                AND name = N'CompatibleLocationTypeDefinitionId')
BEGIN
    ALTER TABLE Tools.ToolType ADD CompatibleLocationTypeDefinitionId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
              WHERE name = N'FK_ToolType_CompatibleLocationTypeDefinition')
BEGIN
    ALTER TABLE Tools.ToolType
        ADD CONSTRAINT FK_ToolType_CompatibleLocationTypeDefinition
        FOREIGN KEY (CompatibleLocationTypeDefinitionId)
        REFERENCES Location.LocationTypeDefinition(Id);
END
GO

-- Seed the Die -> DieCastMachine mapping (idempotent: only sets when unset).
UPDATE tt
SET tt.CompatibleLocationTypeDefinitionId = ltd.Id
FROM Tools.ToolType tt
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Code = N'DieCastMachine'
WHERE tt.Code = N'Die'
  AND tt.CompatibleLocationTypeDefinitionId IS NULL;
GO
