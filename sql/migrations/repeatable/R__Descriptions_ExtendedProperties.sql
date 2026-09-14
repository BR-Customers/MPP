-- ============================================================
-- Repeatable:  R__Descriptions_ExtendedProperties.sql
-- Author:      Blue Ridge Automation
-- Description: MS_Description extended properties for every table
--              and column documented in MPP_MES_DATA_MODEL.md.
--
--              GENERATED FILE -- DO NOT EDIT BY HAND.
--              Regenerate with:
--                  node sql/scripts/gen_extended_properties.js
--
--              Every object is existence-guarded, so a table the
--              document describes but the schema does not carry
--              yet is skipped instead of failing the deploy. Each
--              property is add-or-update, so re-running is a
--              no-op -- which is what makes it repeatable.
--
--              ASCII-only: sqlcmd reads .sql in the Windows
--              codepage, so non-ASCII text would land as mojibake.
-- ============================================================
SET NOCOUNT ON;
GO

-- Location.LocationType
IF OBJECT_ID(N'[Location].[LocationType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The five ISA-95 equipment hierarchy tiers. Seeded at deployment; not operator-editable.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The five ISA-95 equipment hierarchy tiers. Seeded at deployment; not operator-editable.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationType';

    IF COL_LENGTH(N'[Location].[LocationType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Short code (Enterprise, Site, Area, WorkCenter, Cell)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Short code (Enterprise, Site, Area, WorkCenter, Cell)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'HierarchyLevel') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'HierarchyLevel', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'0=Enterprise, 1=Site, 2=Area, 3=WorkCenter, 4=Cell',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'HierarchyLevel';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'0=Enterprise, 1=Site, 2=Area, 3=WorkCenter, 4=Cell',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'HierarchyLevel';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Description',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Description',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'Enterprise') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Enterprise', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Top-level organization (MPP Inc.)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Enterprise';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Top-level organization (MPP Inc.)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Enterprise';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'Site') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Site', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Physical plant/facility',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Site';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Physical plant/facility',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Site';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'Area') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Area', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Subdivision within a site (Die Cast, Trim Shop, Machine Shop, Production Control, Quality Control)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Area';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Subdivision within a site (Die Cast, Trim Shop, Machine Shop, Production Control, Quality Control)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Area';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'WorkCenter') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'WorkCenter', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Production line or grouping of equipment (ISA-95 Work Center)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'WorkCenter';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Production line or grouping of equipment (ISA-95 Work Center)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'WorkCenter';
    END

    IF COL_LENGTH(N'[Location].[LocationType]', N'Cell') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationType]'), N'Cell', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Individual station/unit (ISA-95 Work Unit) - machines, terminals, inventory locations, scales',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Cell';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Individual station/unit (ISA-95 Work Unit) - machines, terminals, inventory locations, scales',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationType',
                         @level2type = N'COLUMN', @level2name = N'Cell';
    END
END
GO

-- Location.LocationTypeDefinition
IF OBJECT_ID(N'[Location].[LocationTypeDefinition]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[LocationTypeDefinition]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Polymorphic kinds within each LocationType. Every Location row references one definition, which determines both its ISA-95 tier (via LocationTypeId) and its attribute schema (via the attached LocationAttributeDefinition rows).',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Polymorphic kinds within each LocationType. Every Location row references one definition, which determines both its ISA-95 tier (via LocationTypeId) and its attribute schema (via the attached LocationAttributeDefinition rows).',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition';

    IF COL_LENGTH(N'[Location].[LocationTypeDefinition]', N'LocationTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationTypeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationTypeDefinition]'), N'LocationTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Which ISA-95 tier this kind belongs to',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'LocationTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Which ISA-95 tier this kind belongs to',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'LocationTypeId';
    END

    IF COL_LENGTH(N'[Location].[LocationTypeDefinition]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationTypeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationTypeDefinition]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Short code (e.g., Terminal, DieCastMachine)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Short code (e.g., Terminal, DieCastMachine)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Location].[LocationTypeDefinition]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationTypeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationTypeDefinition]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Location].[LocationTypeDefinition]', N'Icon') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationTypeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationTypeDefinition]'), N'Icon', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Perspective icon path (e.g., material/precision_manufacturing). Used by tree components. NULL falls back to a default.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Icon';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Perspective icon path (e.g., material/precision_manufacturing). Used by tree components. NULL falls back to a default.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationTypeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Icon';
    END
END
GO

-- Location.LocationAttributeDefinition
IF OBJECT_ID(N'[Location].[LocationAttributeDefinition]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Attribute schema per LocationTypeDefinition. Each definition carries its own set of configurable attributes.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Attribute schema per LocationTypeDefinition. Each definition carries its own set of configurable attributes.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition';

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'LocationTypeDefinitionId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'LocationTypeDefinitionId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Which kind this attribute belongs to',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'LocationTypeDefinitionId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Which kind this attribute belongs to',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'LocationTypeDefinitionId';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'AttributeName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'AttributeName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'e.g., Tonnage, IpAddress, DefaultPrinter',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'e.g., Tonnage, IpAddress, DefaultPrinter',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'DataType') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'DataType', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'INT, DECIMAL, BIT, VARCHAR',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DataType';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'INT, DECIMAL, BIT, VARCHAR',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DataType';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'IsRequired') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'IsRequired', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Must every location of this definition carry a value?',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IsRequired';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Must every location of this definition carry a value?',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IsRequired';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'DefaultValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'DefaultValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Default if not explicitly set',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DefaultValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Default if not explicitly set',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DefaultValue';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'Uom') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'Uom', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Unit of measure for this attribute',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Uom';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Unit of measure for this attribute',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Uom';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'SortOrder') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'SortOrder', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display ordering on config screens',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display ordering on config screens',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'AttributeName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'AttributeName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Uom',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Uom',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'IpAddress') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'IpAddress', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IpAddress';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IpAddress';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'DefaultPrinter') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'DefaultPrinter', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DefaultPrinter';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DefaultPrinter';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'HasBarcodeScanner') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'HasBarcodeScanner', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'HasBarcodeScanner';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'HasBarcodeScanner';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'AttributeName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'AttributeName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Uom',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Uom',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'Tonnage') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'Tonnage', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'tons',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Tonnage';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'tons',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Tonnage';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'RefCycleTimeSec') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'RefCycleTimeSec', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'seconds',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'RefCycleTimeSec';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'seconds',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'RefCycleTimeSec';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'OeeTarget') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'OeeTarget', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'OeeTarget';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'OeeTarget';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'AttributeName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'AttributeName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Uom',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Uom',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'IsPhysical') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'IsPhysical', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IsPhysical';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IsPhysical';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'IsLineside') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'IsLineside', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IsLineside';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'IsLineside';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'MaxLotCapacity') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'MaxLotCapacity', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'MaxLotCapacity';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'-',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'MaxLotCapacity';
    END

    IF COL_LENGTH(N'[Location].[LocationAttributeDefinition]', N'LinesideLimit') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttributeDefinition]'), N'LinesideLimit', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'pieces',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'LinesideLimit';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'pieces',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'LinesideLimit';
    END
END
GO

-- Location.Location
IF OBJECT_ID(N'[Location].[Location]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Every node in the plant model - self-referential hierarchy. Each location references a single LocationTypeDefinition, which determines both its ISA-95 tier and its attribute schema.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'Location';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Every node in the plant model - self-referential hierarchy. Each location references a single LocationTypeDefinition, which determines both its ISA-95 tier and its attribute schema.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'Location';

    IF COL_LENGTH(N'[Location].[Location]', N'LocationTypeDefinitionId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[Location]'), N'LocationTypeDefinitionId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Determines both ISA-95 tier (via join) and attribute schema',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'LocationTypeDefinitionId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Determines both ISA-95 tier (via join) and attribute schema',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'LocationTypeDefinitionId';
    END

    IF COL_LENGTH(N'[Location].[Location]', N'ParentLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[Location]'), N'ParentLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Parent in hierarchy (NULL = root/Enterprise)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'ParentLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Parent in hierarchy (NULL = root/Enterprise)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'ParentLocationId';
    END

    IF COL_LENGTH(N'[Location].[Location]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[Location]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Location].[Location]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[Location]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Short identifier (barcode-scannable for machines)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Short identifier (barcode-scannable for machines)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Location].[Location]', N'SortOrder') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[Location]'), N'SortOrder', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display ordering among siblings. Auto-incremented on creation, updated via move-up/move-down operations.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display ordering among siblings. Auto-incremented on creation, updated via move-up/move-down operations.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
    END

    IF COL_LENGTH(N'[Location].[Location]', N'CoupledDownstreamCellLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[Location]'), N'CoupledDownstreamCellLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Typed column (was a CNCMachine LocationAttribute pre-v1.9p). On a Machining Cell, the Location.Id of the Cell that machined LOTs auto-move to on Machining OUT (FDS-06-008) - typically the paired Assembly Cell in the same WorkCenter. When non-NULL, PLC-signalled machining completion writes a Workorder.ProductionEvent + a Lots.LotMovement from this Cell to the referenced Cell and updates the LOT''s CurrentLocationId - no operator scan. NULL = uncoupled/legacy path: completion writes the ProductionEvent only and the LOT stays put awaiting operator-driven movement. The self-FK gives referential integrity; the "target must be a Cell-tier (Assembly) Location" rule is enforced by the Arc 2 write/config-save proc, not a CHECK (mirrors Tools.ToolType.CompatibleLocationTypeDefinitionId). Migration 0019_location_coupled_downstream_cell.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'CoupledDownstreamCellLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Typed column (was a CNCMachine LocationAttribute pre-v1.9p). On a Machining Cell, the Location.Id of the Cell that machined LOTs auto-move to on Machining OUT (FDS-06-008) - typically the paired Assembly Cell in the same WorkCenter. When non-NULL, PLC-signalled machining completion writes a Workorder.ProductionEvent + a Lots.LotMovement from this Cell to the referenced Cell and updates the LOT''s CurrentLocationId - no operator scan. NULL = uncoupled/legacy path: completion writes the ProductionEvent only and the LOT stays put awaiting operator-driven movement. The self-FK gives referential integrity; the "target must be a Cell-tier (Assembly) Location" rule is enforced by the Arc 2 write/config-save proc, not a CHECK (mirrors Tools.ToolType.CompatibleLocationTypeDefinitionId). Migration 0019_location_coupled_downstream_cell.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'Location',
                         @level2type = N'COLUMN', @level2name = N'CoupledDownstreamCellLocationId';
    END
END
GO

-- Location.LocationAttribute
IF OBJECT_ID(N'[Location].[LocationAttribute]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[LocationAttribute]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Actual attribute values per location, constrained by the location''s definition.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationAttribute';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Actual attribute values per location, constrained by the location''s definition.',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'LocationAttribute';

    IF COL_LENGTH(N'[Location].[LocationAttribute]', N'LocationAttributeDefinitionId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttribute]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttribute]'), N'LocationAttributeDefinitionId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Which attribute (must belong to the location''s definition)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttribute',
                         @level2type = N'COLUMN', @level2name = N'LocationAttributeDefinitionId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Which attribute (must belong to the location''s definition)',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttribute',
                         @level2type = N'COLUMN', @level2name = N'LocationAttributeDefinitionId';
    END

    IF COL_LENGTH(N'[Location].[LocationAttribute]', N'AttributeValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[LocationAttribute]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[LocationAttribute]'), N'AttributeValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Stored as string, parsed per LocationAttributeDefinition.DataType',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttribute',
                         @level2type = N'COLUMN', @level2name = N'AttributeValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Stored as string, parsed per LocationAttributeDefinition.DataType',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'LocationAttribute',
                         @level2type = N'COLUMN', @level2name = N'AttributeValue';
    END
END
GO

-- Location.AppUser
IF OBJECT_ID(N'[Location].[AppUser]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[AppUser]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'MES users in two classes (FDS 4):',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'AppUser';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'MES users in two classes (FDS 4):',
                     @level0type = N'SCHEMA', @level0name = N'Location',
                     @level1type = N'TABLE',  @level1name = N'AppUser';

    IF COL_LENGTH(N'[Location].[AppUser]', N'Initials') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[AppUser]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[AppUser]'), N'Initials', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Shop-floor identification stamp. All classes carry this. Initials populate the Initials field on every shop-floor mutation screen, and remain the human-readable label in reports.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'Initials';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Shop-floor identification stamp. All classes carry this. Initials populate the Initials field on every shop-floor mutation screen, and remain the human-readable label in reports.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'Initials';
    END

    IF COL_LENGTH(N'[Location].[AppUser]', N'Pin') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[AppUser]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[AppUser]'), N'Pin', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'5-digit terminal sign-in identifier. Plaintext by design - an identifier, not a credential (admin-visible, echoed on screen during entry, verifies no secret). UNIQUE is unfiltered, so a retired person''s PIN is never reissued and historical attribution cannot be re-pointed. Leading zeros are significant - full-time 04218 vs temp 40218 - so the column is NVARCHAR and every parameter carrying it is string-typed; a numeric type would strip the zero and lock out every full-time employee.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'Pin';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'5-digit terminal sign-in identifier. Plaintext by design - an identifier, not a credential (admin-visible, echoed on screen during entry, verifies no secret). UNIQUE is unfiltered, so a retired person''s PIN is never reissued and historical attribution cannot be re-pointed. Leading zeros are significant - full-time 04218 vs temp 40218 - so the column is NVARCHAR and every parameter carrying it is string-typed; a numeric type would strip the zero and lock out every full-time employee.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'Pin';
    END

    IF COL_LENGTH(N'[Location].[AppUser]', N'AdAccount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[AppUser]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[AppUser]'), N'AdAccount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Active Directory identity. NULL for Operator class, NOT NULL for Interactive Users.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'AdAccount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Active Directory identity. NULL for Operator class, NOT NULL for Interactive Users.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'AdAccount';
    END

    IF COL_LENGTH(N'[Location].[AppUser]', N'IgnitionRole') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Location].[AppUser]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Location].[AppUser]'), N'IgnitionRole', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL for Operator class. References Ignition''s internal role config for Interactive Users.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'IgnitionRole';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL for Operator class. References Ignition''s internal role config for Interactive Users.',
                         @level0type = N'SCHEMA', @level0name = N'Location',
                         @level1type = N'TABLE',  @level1name = N'AppUser',
                         @level2type = N'COLUMN', @level2name = N'IgnitionRole';
    END
END
GO

-- Parts.ItemType
IF OBJECT_ID(N'[Parts].[ItemType]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Parts].[ItemType]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ItemType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ItemType]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Raw Material, Component, Sub-Assembly, Finished Good, Pass-Through',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemType',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Raw Material, Component, Sub-Assembly, Finished Good, Pass-Through',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemType',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END
END
GO

-- Parts.Uom
IF OBJECT_ID(N'[Parts].[Uom]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Parts].[Uom]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Uom]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Uom]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'EA, LB, KG, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Uom',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'EA, LB, KG, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Uom',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Parts.Item
IF OBJECT_ID(N'[Parts].[Item]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Parts].[Item]', N'PartNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'PartNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'MPP part number',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'PartNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'MPP part number',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'PartNumber';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'MacolaPartNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'MacolaPartNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'ERP cross-reference',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'MacolaPartNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ERP cross-reference',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'MacolaPartNumber';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'DefaultSubLotQty') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'DefaultSubLotQty', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Default pieces per sub-LOT split. Used at Machining OUT when a machined LOT is split across N downstream destinations on a sublotting line (per FDS-05-009).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'DefaultSubLotQty';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Default pieces per sub-LOT split. Used at Machining OUT when a machined LOT is split across N downstream destinations on a sublotting line (per FDS-05-009).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'DefaultSubLotQty';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'MaxLotSize') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'MaxLotSize', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Repurposed v1.9 as PartsPerBasket. One LOT = one basket = one LTT label at Die Cast / Trim / intermediate Machining, so "max parts per LOT" IS basket capacity. Config Tool Item screen labels this field PartsPerBasket. Distinct from MaxParts (see next row). Formal column rename deferred.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'MaxLotSize';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Repurposed v1.9 as PartsPerBasket. One LOT = one basket = one LTT label at Die Cast / Trim / intermediate Machining, so "max parts per LOT" IS basket capacity. Config Tool Item screen labels this field PartsPerBasket. Distinct from MaxParts (see next row). Formal column rename deferred.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'MaxLotSize';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'MaxParts') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'MaxParts', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9c (OI-12 correction). Hard cap on pieces of this Item allowed at any single Location (e.g., "no more than 500 5G0 parts at any one Cell"). Scan-in mutation (LotMovement to a Cell) sums existing pieces of this Item already present at the destination Location across all open LOTs + incoming quantity; rejects if result > MaxParts. Complements LinesideLimit (LocationAttribute on Cell - per-Location aggregate cap across all Items). Stops operators from over-scanning to avoid re-scan friction.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'MaxParts';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9c (OI-12 correction). Hard cap on pieces of this Item allowed at any single Location (e.g., "no more than 500 5G0 parts at any one Cell"). Scan-in mutation (LotMovement to a Cell) sums existing pieces of this Item already present at the destination Location across all open LOTs + incoming quantity; rejects if result > MaxParts. Complements LinesideLimit (LocationAttribute on Cell - per-Location aggregate cap across all Items). Stops operators from over-scanning to avoid re-scan friction.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'MaxParts';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'UomId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'UomId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Counting UOM',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'UomId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Counting UOM',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'UomId';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'UnitWeight') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'UnitWeight', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Weight per piece',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'UnitWeight';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Weight per piece',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'UnitWeight';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'WeightUomId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'WeightUomId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Weight UOM',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'WeightUomId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Weight UOM',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'WeightUomId';
    END

    IF COL_LENGTH(N'[Parts].[Item]', N'CountryOfOrigin') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Item]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Item]'), N'CountryOfOrigin', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'ISO 3166-1 alpha-2 country code (e.g., US, JP, MX). Honda compliance surface - appears on genealogy and shipping output. Added v1.8 (OI-19).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'CountryOfOrigin';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ISO 3166-1 alpha-2 country code (e.g., US, JP, MX). Honda compliance surface - appears on genealogy and shipping output. Added v1.8 (OI-19).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Item',
                         @level2type = N'COLUMN', @level2name = N'CountryOfOrigin';
    END
END
GO

-- Parts.Bom
IF OBJECT_ID(N'[Parts].[Bom]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[Bom]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Versioned bill of materials header. Three-state lifecycle via PublishedAt + DeprecatedAt: Draft (both NULL) -> Published (PublishedAt NOT NULL) -> Deprecated (DeprecatedAt NOT NULL). Drafts are mutable but invisible to production''s GetActiveForItem. Published BOMs are immutable - lines can''t be added/updated/moved/removed; use _CreateNewVersion to fork a new Draft. Same model as RouteTemplate.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'Bom';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Versioned bill of materials header. Three-state lifecycle via PublishedAt + DeprecatedAt: Draft (both NULL) -> Published (PublishedAt NOT NULL) -> Deprecated (DeprecatedAt NOT NULL). Drafts are mutable but invisible to production''s GetActiveForItem. Published BOMs are immutable - lines can''t be added/updated/moved/removed; use _CreateNewVersion to fork a new Draft. Same model as RouteTemplate.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'Bom';

    IF COL_LENGTH(N'[Parts].[Bom]', N'ParentItemId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Bom]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Bom]'), N'ParentItemId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The product this BOM is for',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'ParentItemId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The product this BOM is for',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'ParentItemId';
    END

    IF COL_LENGTH(N'[Parts].[Bom]', N'VersionNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Bom]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Bom]'), N'VersionNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Versioning within the (ParentItemId) family. UNIQUE(ParentItemId, VersionNumber).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'VersionNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Versioning within the (ParentItemId) family. UNIQUE(ParentItemId, VersionNumber).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'VersionNumber';
    END

    IF COL_LENGTH(N'[Parts].[Bom]', N'EffectiveFrom') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Bom]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Bom]'), N'EffectiveFrom', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'When this version becomes active (gated by PublishedAt for production selection)',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'EffectiveFrom';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'When this version becomes active (gated by PublishedAt for production selection)',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'EffectiveFrom';
    END

    IF COL_LENGTH(N'[Parts].[Bom]', N'PublishedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Bom]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Bom]'), N'PublishedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL = Draft (mutable, invisible to production). Non-NULL = Published (immutable, visible). Set by Bom_Publish.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'PublishedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL = Draft (mutable, invisible to production). Non-NULL = Published (immutable, visible). Set by Bom_Publish.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'PublishedAt';
    END

    IF COL_LENGTH(N'[Parts].[Bom]', N'DeprecatedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[Bom]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[Bom]'), N'DeprecatedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Non-NULL = Retired.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Non-NULL = Retired.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'Bom',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
    END
END
GO

-- Parts.BomLine
IF OBJECT_ID(N'[Parts].[BomLine]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[BomLine]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Individual components within a BOM.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'BomLine';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Individual components within a BOM.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'BomLine';

    IF COL_LENGTH(N'[Parts].[BomLine]', N'ChildItemId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[BomLine]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[BomLine]'), N'ChildItemId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Component part',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'BomLine',
                         @level2type = N'COLUMN', @level2name = N'ChildItemId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Component part',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'BomLine',
                         @level2type = N'COLUMN', @level2name = N'ChildItemId';
    END

    IF COL_LENGTH(N'[Parts].[BomLine]', N'QtyPer') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[BomLine]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[BomLine]'), N'QtyPer', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Quantity per parent',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'BomLine',
                         @level2type = N'COLUMN', @level2name = N'QtyPer';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Quantity per parent',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'BomLine',
                         @level2type = N'COLUMN', @level2name = N'QtyPer';
    END
END
GO

-- Parts.RouteTemplate
IF OBJECT_ID(N'[Parts].[RouteTemplate]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[RouteTemplate]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Versioned manufacturing route for a product. Three-state lifecycle via PublishedAt + DeprecatedAt (same pattern as Bom): Draft -> Published -> Deprecated. Drafts are mutable (RouteSteps can be added/updated/moved/removed) but invisible to production. Published routes are immutable.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'RouteTemplate';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Versioned manufacturing route for a product. Three-state lifecycle via PublishedAt + DeprecatedAt (same pattern as Bom): Draft -> Published -> Deprecated. Drafts are mutable (RouteSteps can be added/updated/moved/removed) but invisible to production. Published routes are immutable.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'RouteTemplate';

    IF COL_LENGTH(N'[Parts].[RouteTemplate]', N'VersionNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[RouteTemplate]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[RouteTemplate]'), N'VersionNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'UNIQUE(ItemId, VersionNumber).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteTemplate',
                         @level2type = N'COLUMN', @level2name = N'VersionNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'UNIQUE(ItemId, VersionNumber).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteTemplate',
                         @level2type = N'COLUMN', @level2name = N'VersionNumber';
    END

    IF COL_LENGTH(N'[Parts].[RouteTemplate]', N'PublishedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[RouteTemplate]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[RouteTemplate]'), N'PublishedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL = Draft. Non-NULL = Published (immutable). Set by RouteTemplate_Publish.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteTemplate',
                         @level2type = N'COLUMN', @level2name = N'PublishedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL = Draft. Non-NULL = Published (immutable). Set by RouteTemplate_Publish.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteTemplate',
                         @level2type = N'COLUMN', @level2name = N'PublishedAt';
    END
END
GO

-- Parts.RouteStep
IF OBJECT_ID(N'[Parts].[RouteStep]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[RouteStep]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Ordered steps within a route.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'RouteStep';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Ordered steps within a route.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'RouteStep';

    IF COL_LENGTH(N'[Parts].[RouteStep]', N'OperationTemplateId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[RouteStep]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[RouteStep]'), N'OperationTemplateId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'What happens at this step',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteStep',
                         @level2type = N'COLUMN', @level2name = N'OperationTemplateId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'What happens at this step',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteStep',
                         @level2type = N'COLUMN', @level2name = N'OperationTemplateId';
    END

    IF COL_LENGTH(N'[Parts].[RouteStep]', N'SequenceNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[RouteStep]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[RouteStep]'), N'SequenceNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Execution order',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteStep',
                         @level2type = N'COLUMN', @level2name = N'SequenceNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Execution order',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'RouteStep',
                         @level2type = N'COLUMN', @level2name = N'SequenceNumber';
    END
END
GO

-- Parts.OperationCategory
IF OBJECT_ID(N'[Parts].[OperationCategory]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[OperationCategory]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table grouping operation roles for Config-Tool display. Seeded (3 rows): DieCast (Die Cast), Trim (Trim), MachiningAssembly (Machining & Assembly). Added 2026-07-02 (operation-type restructure, migration 0032).',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationCategory';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table grouping operation roles for Config-Tool display. Seeded (3 rows): DieCast (Die Cast), Trim (Trim), MachiningAssembly (Machining & Assembly). Added 2026-07-02 (operation-type restructure, migration 0032).',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationCategory';

    IF COL_LENGTH(N'[Parts].[OperationCategory]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationCategory]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationCategory]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'DieCast, Trim, MachiningAssembly',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationCategory',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'DieCast, Trim, MachiningAssembly',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationCategory',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Parts.OperationType
IF OBJECT_ID(N'[Parts].[OperationType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[OperationType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table of operation roles - the stable identity a terminal binds to (via its default view / tab focus) so the scanned LOT''s route resolves the right OperationTemplate, and the axis that lets one template be reused across all areas of a kind (e.g. one die-cast template for DC1-DC4). Seeded (8 rows). Added 2026-07-02 (migration 0032).',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table of operation roles - the stable identity a terminal binds to (via its default view / tab focus) so the scanned LOT''s route resolves the right OperationTemplate, and the axis that lets one template be reused across all areas of a kind (e.g. one die-cast template for DC1-DC4). Seeded (8 rows). Added 2026-07-02 (migration 0032).',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationType';

    IF COL_LENGTH(N'[Parts].[OperationType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'DieCast, TrimIn, TrimOut, MachiningIn, MachiningOut, AssemblyIn, AssemblyOut, CNC',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'DieCast, TrimIn, TrimOut, MachiningIn, MachiningOut, AssemblyIn, AssemblyOut, CNC',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Parts].[OperationType]', N'OperationCategoryId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationType]'), N'OperationCategoryId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Grouping category',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationType',
                         @level2type = N'COLUMN', @level2name = N'OperationCategoryId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Grouping category',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationType',
                         @level2type = N'COLUMN', @level2name = N'OperationCategoryId';
    END

    IF COL_LENGTH(N'[Parts].[OperationType]', N'OperationRoleKindId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationType]'), N'OperationRoleKindId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Advance / OriginMint / ConsumeMint (see below). Added 2026-07-07 (migration 0035, terminal-mint model).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationType',
                         @level2type = N'COLUMN', @level2name = N'OperationRoleKindId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Advance / OriginMint / ConsumeMint (see below). Added 2026-07-07 (migration 0035, terminal-mint model).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationType',
                         @level2type = N'COLUMN', @level2name = N'OperationRoleKindId';
    END
END
GO

-- Parts.OperationRoleKind
IF OBJECT_ID(N'[Parts].[OperationRoleKind]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[OperationRoleKind]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table classifying each OperationType role by how the route-driven WIP queue treats a LOT sitting on a step of that role (terminal-mint model, spec 2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md 3.2/4.1). Seeded 3 rows (migration 0035).',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationRoleKind';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table classifying each OperationType role by how the route-driven WIP queue treats a LOT sitting on a step of that role (terminal-mint model, spec 2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md 3.2/4.1). Seeded 3 rows (migration 0035).',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationRoleKind';

    IF COL_LENGTH(N'[Parts].[OperationRoleKind]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationRoleKind]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationRoleKind]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Advance / OriginMint / ConsumeMint',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationRoleKind',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Advance / OriginMint / ConsumeMint',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationRoleKind',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Parts.OperationTemplate
IF OBJECT_ID(N'[Parts].[OperationTemplate]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplate]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Defines what data to collect at a type of operation. Area-agnostic and reusable across products and areas - classified by OperationTypeId (operation role); a terminal resolves the right template by role, so one die-cast template serves all four die-cast areas (2026-07-02 restructure; the former per-area AreaLocationId was dropped). Versioned via Code + VersionNumber - multiple rows share a Code to represent the evolution of one operation over time. See the clone-to-modify workflow in the Phase 5 _CreateNewVersion proc.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationTemplate';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Defines what data to collect at a type of operation. Area-agnostic and reusable across products and areas - classified by OperationTypeId (operation role); a terminal resolves the right template by role, so one die-cast template serves all four die-cast areas (2026-07-02 restructure; the former per-area AreaLocationId was dropped). Versioned via Code + VersionNumber - multiple rows share a Code to represent the evolution of one operation over time. See the clone-to-modify workflow in the Phase 5 _CreateNewVersion proc.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationTemplate';

    IF COL_LENGTH(N'[Parts].[OperationTemplate]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplate]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationTemplate]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operation family code (e.g., DIE-CAST-801T). Multiple rows may share this value across versions.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operation family code (e.g., DIE-CAST-801T). Multiple rows may share this value across versions.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Parts].[OperationTemplate]', N'VersionNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplate]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationTemplate]'), N'VersionNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Version within the Code family. UNIQUE(Code, VersionNumber) enforces one row per version.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'VersionNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Version within the Code family. UNIQUE(Code, VersionNumber) enforces one row per version.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'VersionNumber';
    END

    IF COL_LENGTH(N'[Parts].[OperationTemplate]', N'OperationTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplate]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationTemplate]'), N'OperationTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operation role (see OperationType). Replaces the former AreaLocationId - templates are area-agnostic as of the 2026-07-02 restructure; the executing terminal supplies the area at runtime. RequiresSubLotSplit now correlates to OperationType.Code = ''MachiningOut''.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'OperationTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operation role (see OperationType). Replaces the former AreaLocationId - templates are area-agnostic as of the 2026-07-02 restructure; the executing terminal supplies the area at runtime. RequiresSubLotSplit now correlates to OperationType.Code = ''MachiningOut''.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'OperationTypeId';
    END

    IF COL_LENGTH(N'[Parts].[OperationTemplate]', N'RequiresSubLotSplit') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplate]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationTemplate]'), N'RequiresSubLotSplit', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9m; relocated to Machining OUT in v1.9n. Control flag for outbound flows that split a LOT across multiple downstream destinations (used at Machining OUT per FDS-05-009 - the physical correlate is a line with a dedicated Machining OUT terminal). When 1, the Machining OUT screen presents a multi-destination split UX (one sub-LOT per destination, N total); the closing proc (MachiningOut_RecordSplit) calls Lot_Split and Lot_MoveTo per child. When 0 (default), Machining OUT is the PLC-driven auto-move (coupled) or a manual whole-move (uncoupled) - no split. Engineering authors per Item per Cell via the Configuration Tool. Versioned with the rest of the row per the clone-to-modify pattern. Operations with no outbound-split branch - Die Cast, Receiving, Trim OUT (now a 1:1 whole-LOT move), Machining IN, Assembly - ignore the column. The ALTER lands in Phase 5 migration 0018.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'RequiresSubLotSplit';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9m; relocated to Machining OUT in v1.9n. Control flag for outbound flows that split a LOT across multiple downstream destinations (used at Machining OUT per FDS-05-009 - the physical correlate is a line with a dedicated Machining OUT terminal). When 1, the Machining OUT screen presents a multi-destination split UX (one sub-LOT per destination, N total); the closing proc (MachiningOut_RecordSplit) calls Lot_Split and Lot_MoveTo per child. When 0 (default), Machining OUT is the PLC-driven auto-move (coupled) or a manual whole-move (uncoupled) - no split. Engineering authors per Item per Cell via the Configuration Tool. Versioned with the rest of the row per the clone-to-modify pattern. Operations with no outbound-split branch - Die Cast, Receiving, Trim OUT (now a 1:1 whole-LOT move), Machining IN, Assembly - ignore the column. The ALTER lands in Phase 5 migration 0018.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplate',
                         @level2type = N'COLUMN', @level2name = N'RequiresSubLotSplit';
    END
END
GO

-- Parts.DataCollectionField
IF OBJECT_ID(N'[Parts].[DataCollectionField]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[DataCollectionField]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Extensible vocabulary of data collection capabilities. Seeded with initial set, extensible by engineering.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'DataCollectionField';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Extensible vocabulary of data collection capabilities. Seeded with initial set, extensible by engineering.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'DataCollectionField';

    IF COL_LENGTH(N'[Parts].[DataCollectionField]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[DataCollectionField]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[DataCollectionField]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'MaterialVerification, SerialNumber, DieInfo, CavityInfo, Weight, GoodCount, BadCount',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'DataCollectionField',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'MaterialVerification, SerialNumber, DieInfo, CavityInfo, Weight, GoodCount, BadCount',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'DataCollectionField',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Parts.OperationTemplateField
IF OBJECT_ID(N'[Parts].[OperationTemplateField]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplateField]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Junction: which data collection fields an operation template requires. Replaces the former hardcoded BIT flags on OperationTemplate.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationTemplateField';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Junction: which data collection fields an operation template requires. Replaces the former hardcoded BIT flags on OperationTemplate.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'OperationTemplateField';

    IF COL_LENGTH(N'[Parts].[OperationTemplateField]', N'IsRequired') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[OperationTemplateField]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[OperationTemplateField]'), N'IsRequired', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Whether this field is mandatory or optional for this operation',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplateField',
                         @level2type = N'COLUMN', @level2name = N'IsRequired';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Whether this field is mandatory or optional for this operation',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'OperationTemplateField',
                         @level2type = N'COLUMN', @level2name = N'IsRequired';
    END
END
GO

-- Parts.ItemLocation
IF OBJECT_ID(N'[Parts].[ItemLocation]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[ItemLocation]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Part-to-location eligibility (which parts can run where) plus consumption metadata for runtime Allocations.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'ItemLocation';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Part-to-location eligibility (which parts can run where) plus consumption metadata for runtime Allocations.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'ItemLocation';

    IF COL_LENGTH(N'[Parts].[ItemLocation]', N'LocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ItemLocation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ItemLocation]'), N'LocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'v1.9d: any tier (Area, WorkCenter, Cell). Eligibility at a Cell = ItemLocation row exists for the Cell OR any ancestor.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'v1.9d: any tier (Area, WorkCenter, Cell). Eligibility at a Cell = ItemLocation row exists for the Cell OR any ancestor.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
    END

    IF COL_LENGTH(N'[Parts].[ItemLocation]', N'MinQuantity') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ItemLocation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ItemLocation]'), N'MinQuantity', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Minimum pieces per scan-in at this Cell for this Item. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'MinQuantity';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Minimum pieces per scan-in at this Cell for this Item. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'MinQuantity';
    END

    IF COL_LENGTH(N'[Parts].[ItemLocation]', N'MaxQuantity') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ItemLocation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ItemLocation]'), N'MaxQuantity', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Maximum pieces per scan-in - rejects over-scan. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'MaxQuantity';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Maximum pieces per scan-in - rejects over-scan. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'MaxQuantity';
    END

    IF COL_LENGTH(N'[Parts].[ItemLocation]', N'DefaultQuantity') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ItemLocation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ItemLocation]'), N'DefaultQuantity', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Pre-populated quantity on the Allocations scan form. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'DefaultQuantity';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pre-populated quantity on the Allocations scan form. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'DefaultQuantity';
    END

    IF COL_LENGTH(N'[Parts].[ItemLocation]', N'IsConsumptionPoint') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ItemLocation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ItemLocation]'), N'IsConsumptionPoint', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'1 = this Cell consumes this Item (input); 0 = this Cell produces this Item (output) or is merely eligible. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'IsConsumptionPoint';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = this Cell consumes this Item (input); 0 = this Cell produces this Item (output) or is merely eligible. Added v1.8 (OI-18).',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ItemLocation',
                         @level2type = N'COLUMN', @level2name = N'IsConsumptionPoint';
    END
END
GO

-- Parts.ContainerConfig
IF OBJECT_ID(N'[Parts].[ContainerConfig]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Parts].[ContainerConfig]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Honda-specified packing rules per product.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'ContainerConfig';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Honda-specified packing rules per product.',
                     @level0type = N'SCHEMA', @level0name = N'Parts',
                     @level1type = N'TABLE',  @level1name = N'ContainerConfig';

    IF COL_LENGTH(N'[Parts].[ContainerConfig]', N'ClosureMethod') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ContainerConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ContainerConfig]'), N'ClosureMethod', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'One of ByCount, ByWeight, or ByVision (NULL when not yet configured). Selects the tray-level closure trigger per FDS-06-014. ByCount = operator-entered count per tray; ByWeight = scale feedback via OmniServer (target on TargetWeight, PLC asserts TrayFullFlag at threshold); ByVision = camera validates the full tray as a single image (one validation event per tray, not per piece), PLC asserts TrayFullFlag on pass. Container fill is derived in MES from accumulated tray closes - no separate ContainerFullFlag PLC tag is required. ClosureMethod is a per-Item / per-customer attribute - a ByVision part and a ByCount part may run on the same physical line for different customers, each with its own ContainerConfig. The binding to a camera/MIP-capable Cell is routing-trusted, not proc-enforced (decided 2026-06-04): Engineering routes a ByVision part to a vision-equipped Cell; a mis-route simply...',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'ClosureMethod';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'One of ByCount, ByWeight, or ByVision (NULL when not yet configured). Selects the tray-level closure trigger per FDS-06-014. ByCount = operator-entered count per tray; ByWeight = scale feedback via OmniServer (target on TargetWeight, PLC asserts TrayFullFlag at threshold); ByVision = camera validates the full tray as a single image (one validation event per tray, not per piece), PLC asserts TrayFullFlag on pass. Container fill is derived in MES from accumulated tray closes - no separate ContainerFullFlag PLC tag is required. ClosureMethod is a per-Item / per-customer attribute - a ByVision part and a ByCount part may run on the same physical line for different customers, each with its own ContainerConfig. The binding to a camera/MIP-capable Cell is routing-trusted, not proc-enforced (decided 2026-06-04): Engineering routes a ByVision part to a vision-equipped Cell; a mis-route simply...',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'ClosureMethod';
    END

    IF COL_LENGTH(N'[Parts].[ContainerConfig]', N'TargetWeight') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ContainerConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ContainerConfig]'), N'TargetWeight', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Target weight for ByWeight closure. Required when ClosureMethod = ''ByWeight''; ignored otherwise.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'TargetWeight';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Target weight for ByWeight closure. Required when ClosureMethod = ''ByWeight''; ignored otherwise.',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'TargetWeight';
    END

    IF COL_LENGTH(N'[Parts].[ContainerConfig]', N'DunnageCode') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ContainerConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ContainerConfig]'), N'DunnageCode', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Returnable dunnage identifier',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'DunnageCode';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Returnable dunnage identifier',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'DunnageCode';
    END

    IF COL_LENGTH(N'[Parts].[ContainerConfig]', N'CustomerCode') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Parts].[ContainerConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Parts].[ContainerConfig]'), N'CustomerCode', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Honda customer code',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'CustomerCode';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Honda customer code',
                         @level0type = N'SCHEMA', @level0name = N'Parts',
                         @level1type = N'TABLE',  @level1name = N'ContainerConfig',
                         @level2type = N'COLUMN', @level2name = N'CustomerCode';
    END
END
GO

-- Lots.LotOriginType
IF OBJECT_ID(N'[Lots].[LotOriginType]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Lots].[LotOriginType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotOriginType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotOriginType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Manufactured, Received, ReceivedOffsite',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotOriginType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Manufactured, Received, ReceivedOffsite',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotOriginType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Lots.LotStatusCode
IF OBJECT_ID(N'[Lots].[LotStatusCode]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[LotStatusCode]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Open (added migration 0045, 2026-07-29 - Die Cast per-cavity lifecycle). BlocksProduction = 0; appended Id (the original 1-4 rows are unchanged). Represents a die-cast accumulator basket - the LOT exists (has a scanned LTT, a ToolId + ToolCavityId) and is accumulating good pieces at the press, but is not yet on its route: Lots.v_LotDerivedQuantities.TotalInProcess = 0 for an Open LOT, and Lot_GetWipQueueByLocation explicitly excludes it (sc.Code NOT IN (''Closed'',''Open'')) so it never surfaces to the Trim IN queue prematurely. Lots.DieCastLot_Open mints it; Lots.DieCastLot_Release transitions Open -> Good and performs the LOT''s first LotMovement (cell -> warehouse storage), the moment it first becomes route-visible; Lots.DieCastLot_Void transitions an empty Open basket straight to Scrap. See Workorder.DieCastContribution below for how good pieces accumulate on an Open LOT.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotStatusCode';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Open (added migration 0045, 2026-07-29 - Die Cast per-cavity lifecycle). BlocksProduction = 0; appended Id (the original 1-4 rows are unchanged). Represents a die-cast accumulator basket - the LOT exists (has a scanned LTT, a ToolId + ToolCavityId) and is accumulating good pieces at the press, but is not yet on its route: Lots.v_LotDerivedQuantities.TotalInProcess = 0 for an Open LOT, and Lot_GetWipQueueByLocation explicitly excludes it (sc.Code NOT IN (''Closed'',''Open'')) so it never surfaces to the Trim IN queue prematurely. Lots.DieCastLot_Open mints it; Lots.DieCastLot_Release transitions Open -> Good and performs the LOT''s first LotMovement (cell -> warehouse storage), the moment it first becomes route-visible; Lots.DieCastLot_Void transitions an empty Open basket straight to Scrap. See Workorder.DieCastContribution below for how good pieces accumulate on an Open LOT.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotStatusCode';

    IF COL_LENGTH(N'[Lots].[LotStatusCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotStatusCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotStatusCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Good, Hold, Scrap, Closed, Open',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Good, Hold, Scrap, Closed, Open',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Lots].[LotStatusCode]', N'BlocksProduction') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotStatusCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotStatusCode]'), N'BlocksProduction', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Hold = true, drives interlocks',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotStatusCode',
                         @level2type = N'COLUMN', @level2name = N'BlocksProduction';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Hold = true, drives interlocks',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotStatusCode',
                         @level2type = N'COLUMN', @level2name = N'BlocksProduction';
    END
END
GO

-- Lots.GenealogyRelationshipType
IF OBJECT_ID(N'[Lots].[GenealogyRelationshipType]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Lots].[GenealogyRelationshipType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[GenealogyRelationshipType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[GenealogyRelationshipType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Split, Merge, Consumption',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'GenealogyRelationshipType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Split, Merge, Consumption',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'GenealogyRelationshipType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Lots.Lot
IF OBJECT_ID(N'[Lots].[Lot]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The central tracking entity.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'Lot';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The central tracking entity.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'Lot';

    IF COL_LENGTH(N'[Lots].[Lot]', N'LotName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'LotName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The LTT barcode number',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'LotName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The LTT barcode number',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'LotName';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'LotOriginTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'LotOriginTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'How it entered MES',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'LotOriginTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'How it entered MES',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'LotOriginTypeId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'LotStatusId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'LotStatusId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Current quality status',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'LotStatusId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Current quality status',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'LotStatusId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'PieceCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'PieceCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Current count',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'PieceCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Current count',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'PieceCount';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'MaxPieceCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'MaxPieceCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Reasonability ceiling',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'MaxPieceCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Reasonability ceiling',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'MaxPieceCount';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'ToolId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'ToolId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9. Required at Lot_Create for die-cast-origin LOTs (validated against Tools.ToolAssignment_ListActiveByCell - the Tool must be currently mounted on the cell). NULL for other origins (Received, Trim / Machining intermediate, Assembly, Serialized). NULL after Lot_Merge on blended-origin LOTs (can''t denormalize multiple Tools). Downstream LOTs do NOT carry - Honda-trace via LotGenealogy traversal.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9. Required at Lot_Create for die-cast-origin LOTs (validated against Tools.ToolAssignment_ListActiveByCell - the Tool must be currently mounted on the cell). NULL for other origins (Received, Trim / Machining intermediate, Assembly, Serialized). NULL after Lot_Merge on blended-origin LOTs (can''t denormalize multiple Tools). Downstream LOTs do NOT carry - Honda-trace via LotGenealogy traversal.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'ToolCavityId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'ToolCavityId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9. Required at Lot_Create for die-cast-origin LOTs (validated: cavity belongs to ToolId + cavity status is Active). NULL elsewhere.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ToolCavityId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9. Required at Lot_Create for die-cast-origin LOTs (validated: cavity belongs to ToolId + cavity status is Active). NULL elsewhere.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ToolCavityId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'ProducedAtLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'ProducedAtLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v2.4 (migration 0082). The die cast machine that produced this LOT. Written only by the inventory cutover scan: a LOT born at a die cast terminal derives its machine from CreatedAtTerminalId''s parent, but a cutover LOT is created at a machining terminal weeks after the casting, so the machine exists only on the paper tag. NULL for every non-cutover LOT and for every received purchased component. Not to be confused with DieNumber, which is the legacy DIE column.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ProducedAtLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v2.4 (migration 0082). The die cast machine that produced this LOT. Written only by the inventory cutover scan: a LOT born at a die cast terminal derives its machine from CreatedAtTerminalId''s parent, but a cutover LOT is created at a machining terminal weeks after the casting, so the machine exists only on the paper tag. NULL for every non-cutover LOT and for every received purchased component. Not to be confused with DieNumber, which is the legacy DIE column.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ProducedAtLocationId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'DieNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'DieNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Legacy as of v1.9 - superseded by ToolId FK above. Retained this release to support any cutover script needing the NVARCHAR form; scheduled for removal in a follow-up migration once all writers move to the Tool FK.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'DieNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Legacy as of v1.9 - superseded by ToolId FK above. Retained this release to support any cutover script needing the NVARCHAR form; scheduled for removal in a follow-up migration once all writers move to the Tool FK.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'DieNumber';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'VendorLotNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'VendorLotNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Received LOTs only',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'VendorLotNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Received LOTs only',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'VendorLotNumber';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'MinSerialNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'MinSerialNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Vendor serial range (received bulk parts)',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'MinSerialNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Vendor serial range (received bulk parts)',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'MinSerialNumber';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'ParentLotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'ParentLotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Adjacency list link for Machining sub-LOTs (FDS 5.4). Not used for cavity-parallel LOTs at Die Cast - those are peers, not parent/child.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ParentLotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Adjacency list link for Machining sub-LOTs (FDS 5.4). Not used for cavity-parallel LOTs at Die Cast - those are peers, not parent/child.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'ParentLotId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'CurrentLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'CurrentLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Where this LOT is now',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'CurrentLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Where this LOT is now',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'CurrentLocationId';
    END

    IF COL_LENGTH(N'[Lots].[Lot]', N'CrtActive') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Lot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Lot]'), N'CrtActive', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9q (FDS-10-012). Controlled Run Tag flag. When 1, downstream operations require 200% inspection (every part, captured via Quality.QualitySample) until cleared by a supervisor-elevated release. Missed CRT inspections (MissedCrtInspect) are detected against the per-operation inspection record. Set / cleared by the Arc 2 CRT workflow; MVP-ratified 2026-06-08.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'CrtActive';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9q (FDS-10-012). Controlled Run Tag flag. When 1, downstream operations require 200% inspection (every part, captured via Quality.QualitySample) until cleared by a supervisor-elevated release. Missed CRT inspections (MissedCrtInspect) are detected against the per-operation inspection record. Set / cleared by the Arc 2 CRT workflow; MVP-ratified 2026-06-08.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Lot',
                         @level2type = N'COLUMN', @level2name = N'CrtActive';
    END
END
GO

-- Lots.LotGenealogy
IF OBJECT_ID(N'[Lots].[LotGenealogy]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[LotGenealogy]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Edge table for the genealogy graph. Adjacency list supporting recursive CTE traversal.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotGenealogy';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Edge table for the genealogy graph. Adjacency list supporting recursive CTE traversal.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotGenealogy';

    IF COL_LENGTH(N'[Lots].[LotGenealogy]', N'RelationshipTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotGenealogy]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotGenealogy]'), N'RelationshipTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Split, Merge, Consumption',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotGenealogy',
                         @level2type = N'COLUMN', @level2name = N'RelationshipTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Split, Merge, Consumption',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotGenealogy',
                         @level2type = N'COLUMN', @level2name = N'RelationshipTypeId';
    END

    IF COL_LENGTH(N'[Lots].[LotGenealogy]', N'PieceCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotGenealogy]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotGenealogy]'), N'PieceCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Pieces transferred in this relationship',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotGenealogy',
                         @level2type = N'COLUMN', @level2name = N'PieceCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pieces transferred in this relationship',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotGenealogy',
                         @level2type = N'COLUMN', @level2name = N'PieceCount';
    END

    IF COL_LENGTH(N'[Lots].[LotGenealogy]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotGenealogy]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotGenealogy]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotGenealogy',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotGenealogy',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END
END
GO

-- Lots.LotStatusHistory
IF OBJECT_ID(N'[Lots].[LotStatusHistory]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[LotStatusHistory]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Immutable log of every status transition.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotStatusHistory';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Immutable log of every status transition.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotStatusHistory';

    IF COL_LENGTH(N'[Lots].[LotStatusHistory]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotStatusHistory]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotStatusHistory]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotStatusHistory',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotStatusHistory',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END
END
GO

-- Lots.LotMovement
IF OBJECT_ID(N'[Lots].[LotMovement]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[LotMovement]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Append-only location change log.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotMovement';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Append-only location change log.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotMovement';

    IF COL_LENGTH(N'[Lots].[LotMovement]', N'FromLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotMovement]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotMovement]'), N'FromLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL on first placement',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotMovement',
                         @level2type = N'COLUMN', @level2name = N'FromLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL on first placement',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotMovement',
                         @level2type = N'COLUMN', @level2name = N'FromLocationId';
    END

    IF COL_LENGTH(N'[Lots].[LotMovement]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotMovement]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotMovement]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotMovement',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotMovement',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END
END
GO

-- Lots.LotAttributeChange
IF OBJECT_ID(N'[Lots].[LotAttributeChange]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[LotAttributeChange]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Audit log for attribute modifications.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotAttributeChange';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Audit log for attribute modifications.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotAttributeChange';

    IF COL_LENGTH(N'[Lots].[LotAttributeChange]', N'AttributeName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotAttributeChange]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotAttributeChange]'), N'AttributeName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'e.g., PieceCount, Weight',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotAttributeChange',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'e.g., PieceCount, Weight',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotAttributeChange',
                         @level2type = N'COLUMN', @level2name = N'AttributeName';
    END

    IF COL_LENGTH(N'[Lots].[LotAttributeChange]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotAttributeChange]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotAttributeChange]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotAttributeChange',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotAttributeChange',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END
END
GO

-- Lots.PrintReasonCode
IF OBJECT_ID(N'[Lots].[PrintReasonCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Lots].[PrintReasonCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PrintReasonCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PrintReasonCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Initial, ReprintDamaged, Split, Merge, SortCageReIdentify',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PrintReasonCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Initial, ReprintDamaged, Split, Merge, SortCageReIdentify',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PrintReasonCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Lots.IdentifierSequence
IF OBJECT_ID(N'[Lots].[IdentifierSequence]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9 (OI-31). Replaces Flexware''s IdentifierFormat table and drives all MPP-internal identifier minting - Lot LTT barcode (MESL{0:D7}), SerializedItem ID (MESI{0:D7}), and any future non-AIM counters. Honda AIM shipper IDs are out of scope (those come from AIM.GetNextNumber). Cutover-day migration seeds LastValue at or above the live Flexware value to avoid collisions with in-circulation LOTs.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'IdentifierSequence';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9 (OI-31). Replaces Flexware''s IdentifierFormat table and drives all MPP-internal identifier minting - Lot LTT barcode (MESL{0:D7}), SerializedItem ID (MESI{0:D7}), and any future non-AIM counters. Honda AIM shipper IDs are out of scope (those come from AIM.GetNextNumber). Cutover-day migration seeds LastValue at or above the live Flexware value to avoid collisions with in-circulation LOTs.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'IdentifierSequence';

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Sequence key (e.g., Lot, SerializedItem). Passed to IdentifierSequence_Next @Code.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Sequence key (e.g., Lot, SerializedItem). Passed to IdentifierSequence_Next @Code.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'FormatString') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'FormatString', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'.NET string.Format pattern, e.g., MESL{0:D7} produces MESL0000001 for value 1.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'FormatString';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'.NET string.Format pattern, e.g., MESL{0:D7} produces MESL0000001 for value 1.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'FormatString';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'StartingValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'StartingValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Lower bound of the numeric range',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'StartingValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Lower bound of the numeric range',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'StartingValue';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'EndingValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'EndingValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Upper bound before rollover - IdentifierSequence_Next raises a business-rule error when LastValue + 1 > EndingValue without an explicit reset policy',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'EndingValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Upper bound before rollover - IdentifierSequence_Next raises a business-rule error when LastValue + 1 > EndingValue without an explicit reset policy',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'EndingValue';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'LastValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'LastValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Most recent issued numeric value. IdentifierSequence_Next atomically increments this and returns the formatted string.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'LastValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Most recent issued numeric value. IdentifierSequence_Next atomically increments this and returns the formatted string.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'LastValue';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'ResetIntervalMinutes') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'ResetIntervalMinutes', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Unused at MPP today (Flexware has no reset policy); nullable for future line/shift-specific reset rules if MPP elects them.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'ResetIntervalMinutes';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Unused at MPP today (Flexware has no reset policy); nullable for future line/shift-specific reset rules if MPP elects them.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'ResetIntervalMinutes';
    END

    IF COL_LENGTH(N'[Lots].[IdentifierSequence]', N'LastResetAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[IdentifierSequence]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[IdentifierSequence]'), N'LastResetAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Timestamp of last reset (manual or scheduled); unused at MPP today',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'LastResetAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Timestamp of last reset (manual or scheduled); unused at MPP today',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'IdentifierSequence',
                         @level2type = N'COLUMN', @level2name = N'LastResetAt';
    END
END
GO

-- Lots.LotLabel
IF OBJECT_ID(N'[Lots].[LotLabel]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[LotLabel]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'LTT barcode label print/reprint tracking.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotLabel';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'LTT barcode label print/reprint tracking.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'LotLabel';

    IF COL_LENGTH(N'[Lots].[LotLabel]', N'PrintReasonCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotLabel]'), N'PrintReasonCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Why this label was printed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintReasonCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Why this label was printed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintReasonCodeId';
    END

    IF COL_LENGTH(N'[Lots].[LotLabel]', N'ZplContent') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotLabel]'), N'ZplContent', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Full ZPL payload',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'ZplContent';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Full ZPL payload',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'ZplContent';
    END

    IF COL_LENGTH(N'[Lots].[LotLabel]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotLabel]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END

    IF COL_LENGTH(N'[Lots].[LotLabel]', N'RfidTag') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[LotLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[LotLabel]'), N'RfidTag', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Reserved placeholder for a future RFID-encoding phase (migration 0070). Not populated or read anywhere yet.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'RfidTag';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Reserved placeholder for a future RFID-encoding phase (migration 0070). Not populated or read anywhere yet.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'LotLabel',
                         @level2type = N'COLUMN', @level2name = N'RfidTag';
    END
END
GO

-- Lots.ContainerStatusCode
IF OBJECT_ID(N'[Lots].[ContainerStatusCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Lots].[ContainerStatusCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ContainerStatusCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ContainerStatusCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Open, Complete, Shipped, Hold, Void',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ContainerStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Open, Complete, Shipped, Hold, Void',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ContainerStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Lots.Container
IF OBJECT_ID(N'[Lots].[Container]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[Container]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Shipping containers for finished goods.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'Container';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Shipping containers for finished goods.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'Container';

    IF COL_LENGTH(N'[Lots].[Container]', N'LotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Container]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Container]'), N'LotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Source LOT',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'LotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Source LOT',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'LotId';
    END

    IF COL_LENGTH(N'[Lots].[Container]', N'StationLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Container]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Container]'), N'StationLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The terminal that owns this open box (migration 0078). Workorder.Assembly_CompleteTray v1.4 files a tray into the station''s own open box for (line, part), else claims an unowned open box for (line, part), else opens one owned by the station. NULL = unowned: every pre-0078 container, and any box opened by a caller that passes no Terminal. Filtered index IX_Container_OpenByCellItemStation on open rows. Why: METTs A and B on MA2-6MACH run the same part numbers at once into physically separate boxes.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'StationLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The terminal that owns this open box (migration 0078). Workorder.Assembly_CompleteTray v1.4 files a tray into the station''s own open box for (line, part), else claims an unowned open box for (line, part), else opens one owned by the station. NULL = unowned: every pre-0078 container, and any box opened by a caller that passes no Terminal. Filtered index IX_Container_OpenByCellItemStation on open rows. Why: METTs A and B on MA2-6MACH run the same part numbers at once into physically separate boxes.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'StationLocationId';
    END

    IF COL_LENGTH(N'[Lots].[Container]', N'AimShipperId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Container]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Container]'), N'AimShipperId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'From AIM system',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'AimShipperId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'From AIM system',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'AimShipperId';
    END

    IF COL_LENGTH(N'[Lots].[Container]', N'HoldNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[Container]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[Container]'), N'HoldNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Sort Cage hold reference',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'HoldNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Sort Cage hold reference',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'Container',
                         @level2type = N'COLUMN', @level2name = N'HoldNumber';
    END
END
GO

-- Lots.ContainerTray
IF OBJECT_ID(N'[Lots].[ContainerTray]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[ContainerTray]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Assembly consumption targets the finished-good LOT (v-bump 2026-07-06). Non-serialized AND serialized assembly-out mint a finished-good LOT (tray = LOT) and consume BomLine.QtyPer x PieceCount FIFO (oldest-first by Lot.CreatedAt, tie-broken by Id) from eligible component LOTs at the line. Each draw''s Workorder.ConsumptionEvent sets ProducedLotId = the finished-good LOT (the primary consumption target), not only ProducedContainerId; the Container is retained as the wrapper. See FDS-06-013 / FDS-06-020 / FDS-06-021.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'ContainerTray';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Assembly consumption targets the finished-good LOT (v-bump 2026-07-06). Non-serialized AND serialized assembly-out mint a finished-good LOT (tray = LOT) and consume BomLine.QtyPer x PieceCount FIFO (oldest-first by Lot.CreatedAt, tie-broken by Id) from eligible component LOTs at the line. Each draw''s Workorder.ConsumptionEvent sets ProducedLotId = the finished-good LOT (the primary consumption target), not only ProducedContainerId; the Container is retained as the wrapper. See FDS-06-013 / FDS-06-020 / FDS-06-021.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'ContainerTray';

    IF COL_LENGTH(N'[Lots].[ContainerTray]', N'FinishedGoodLotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ContainerTray]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ContainerTray]'), N'FinishedGoodLotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Finished-good LOT minted at tray closure - tray = LOT, 1:1. Assembly-out consumption targets this LOT via ConsumptionEvent.ProducedLotId (see below), and container genealogy resolves Container -> ContainerTray -> FinishedGoodLot -> component LOTs. Nullable during transition; tightened to NOT NULL once all trays route through Workorder.Assembly_CompleteTray.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ContainerTray',
                         @level2type = N'COLUMN', @level2name = N'FinishedGoodLotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Finished-good LOT minted at tray closure - tray = LOT, 1:1. Assembly-out consumption targets this LOT via ConsumptionEvent.ProducedLotId (see below), and container genealogy resolves Container -> ContainerTray -> FinishedGoodLot -> component LOTs. Nullable during transition; tightened to NOT NULL once all trays route through Workorder.Assembly_CompleteTray.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ContainerTray',
                         @level2type = N'COLUMN', @level2name = N'FinishedGoodLotId';
    END
END
GO

-- Lots.SerializedPart
IF OBJECT_ID(N'[Lots].[SerializedPart]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[SerializedPart]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Individual laser-etched serial numbers.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'SerializedPart';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Individual laser-etched serial numbers.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'SerializedPart';

    IF COL_LENGTH(N'[Lots].[SerializedPart]', N'LotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[SerializedPart]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[SerializedPart]'), N'LotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Source LOT',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'SerializedPart',
                         @level2type = N'COLUMN', @level2name = N'LotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Source LOT',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'SerializedPart',
                         @level2type = N'COLUMN', @level2name = N'LotId';
    END

    IF COL_LENGTH(N'[Lots].[SerializedPart]', N'ContainerId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[SerializedPart]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[SerializedPart]'), N'ContainerId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Current container',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'SerializedPart',
                         @level2type = N'COLUMN', @level2name = N'ContainerId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Current container',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'SerializedPart',
                         @level2type = N'COLUMN', @level2name = N'ContainerId';
    END
END
GO

-- Lots.ContainerSerial
IF OBJECT_ID(N'[Lots].[ContainerSerial]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[ContainerSerial]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Junction: serial numbers in container tray positions.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'ContainerSerial';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Junction: serial numbers in container tray positions.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'ContainerSerial';

    IF COL_LENGTH(N'[Lots].[ContainerSerial]', N'TrayPosition') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ContainerSerial]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ContainerSerial]'), N'TrayPosition', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Position within tray',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ContainerSerial',
                         @level2type = N'COLUMN', @level2name = N'TrayPosition';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Position within tray',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ContainerSerial',
                         @level2type = N'COLUMN', @level2name = N'TrayPosition';
    END
END
GO

-- Lots.ShippingLabel
IF OBJECT_ID(N'[Lots].[ShippingLabel]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Container shipping label print/void history. v1.9i (UJ-18 Gateway-script-async print pattern): print state lives on this row - no separate queue table. Operator close transaction is atomic and zero-latency (same v1.9h AIM pool flow); print dispatch is event-driven via Gateway message handler with 3 retries (2s gap), banner-on-failure at the closing terminal. v1.9k: BannerAcknowledgedAt added to record operator dismissal of the print-failure banner - supports the FDS-07-006b broadcast-with-session-filter Acknowledge action.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'ShippingLabel';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Container shipping label print/void history. v1.9i (UJ-18 Gateway-script-async print pattern): print state lives on this row - no separate queue table. Operator close transaction is atomic and zero-latency (same v1.9h AIM pool flow); print dispatch is event-driven via Gateway message handler with 3 retries (2s gap), banner-on-failure at the closing terminal. v1.9k: BannerAcknowledgedAt added to record operator dismissal of the print-failure banner - supports the FDS-07-006b broadcast-with-session-filter Acknowledge action.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'ShippingLabel';

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'AimShipperId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'AimShipperId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'From the AimShipperIdPool claim at close time.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'AimShipperId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'From the AimShipperIdPool claim at close time.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'AimShipperId';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'ZplContent') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'ZplContent', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Full ZPL payload',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'ZplContent';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Full ZPL payload',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'ZplContent';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'PrintedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'PrintedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL until the Gateway print handler succeeds.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL until the Gateway print handler succeeds.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintedAt';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'PrintAttempts') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'PrintAttempts', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Increments per print attempt by the Gateway message handler.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintAttempts';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Increments per print attempt by the Gateway message handler.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintAttempts';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'LastPrintAttemptAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'LastPrintAttemptAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Timestamp of most recent print try.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'LastPrintAttemptAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Timestamp of most recent print try.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'LastPrintAttemptAt';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'LastPrintError') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'LastPrintError', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Captured exception text from the most recent failed attempt.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'LastPrintError';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Captured exception text from the most recent failed attempt.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'LastPrintError';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'PrintFailedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'PrintFailedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Non-NULL = retries exhausted (3 attempts x 2s gap). Drives the banner shown at TerminalLocationId.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintFailedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. Non-NULL = retries exhausted (3 attempts x 2s gap). Drives the banner shown at TerminalLocationId.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'PrintFailedAt';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. The Terminal where the closing operator was - drives both the printer pick (resolved via LocationAttribute on parent Cell) and the banner routing (banner shows only at this Terminal).',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9i. The Terminal where the closing operator was - drives both the printer pick (resolved via LocationAttribute on parent Cell) and the banner routing (banner shows only at this Terminal).',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'BannerAcknowledgedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'BannerAcknowledgedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9k. Non-NULL when the operator at TerminalLocationId dismissed the print-failure banner via the Acknowledge action (FDS-07-006b). Independent of PrintFailedAt - the row stays in failed state for the safety-sweep alarm even after acknowledgement; this column only suppresses the banner UI. NULL while the banner is active.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'BannerAcknowledgedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9k. Non-NULL when the operator at TerminalLocationId dismissed the print-failure banner via the Acknowledge action (FDS-07-006b). Independent of PrintFailedAt - the row stays in failed state for the safety-sweep alarm even after acknowledgement; this column only suppresses the banner UI. NULL while the banner is active.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'BannerAcknowledgedAt';
    END

    IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'RfidTag') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[ShippingLabel]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[ShippingLabel]'), N'RfidTag', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Reserved placeholder for a future RFID-encoding phase (migration 0070). Not populated or read anywhere yet.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'RfidTag';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Reserved placeholder for a future RFID-encoding phase (migration 0070). Not populated or read anywhere yet.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'ShippingLabel',
                         @level2type = N'COLUMN', @level2name = N'RfidTag';
    END
END
GO

-- Lots.PauseEvent
IF OBJECT_ID(N'[Lots].[PauseEvent]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9g (OI-21 - Pausable LOT at Workstation). Captures an operator''s deliberate pause of a partially-progressed LOT at a Cell so the operator may shift focus to a different LOT at the same Cell. Append-only place + close lifecycle - mirrors Quality.HoldEvent. The same LOT MAY be paused at multiple Cells simultaneously (e.g., a Machining LOT pending mid-assembly while another assembly LOT is run); the filtered UNIQUE limits at most one open pause per (LotId, LocationId). Pause is orthogonal to Workorder.WorkOrderStatus, Workorder.OperationStatus, and Lots.LotStatusCode - no enum extension is required on any of those code tables. There is no TTL - paused LOTs persist indefinitely; resume MAY be performed by any operator (does not need to match PausedByUserId). Drives the Paused-LOT indicator on every workstation screen (count + tap-through to detail list, per FDS-05-038).',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'PauseEvent';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9g (OI-21 - Pausable LOT at Workstation). Captures an operator''s deliberate pause of a partially-progressed LOT at a Cell so the operator may shift focus to a different LOT at the same Cell. Append-only place + close lifecycle - mirrors Quality.HoldEvent. The same LOT MAY be paused at multiple Cells simultaneously (e.g., a Machining LOT pending mid-assembly while another assembly LOT is run); the filtered UNIQUE limits at most one open pause per (LotId, LocationId). Pause is orthogonal to Workorder.WorkOrderStatus, Workorder.OperationStatus, and Lots.LotStatusCode - no enum extension is required on any of those code tables. There is no TTL - paused LOTs persist indefinitely; resume MAY be performed by any operator (does not need to match PausedByUserId). Drives the Paused-LOT indicator on every workstation screen (count + tap-through to detail list, per FDS-05-038).',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'PauseEvent';

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'LotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'LotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The LOT being paused at this Cell.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'LotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The LOT being paused at this Cell.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'LotId';
    END

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'LocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'LocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The Cell where the pause is recorded. Should be a Cell-tier production location; not enforced at the schema level (proc layer enforces).',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The Cell where the pause is recorded. Should be a Cell-tier production location; not enforced at the schema level (proc layer enforces).',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
    END

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'PausedByUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'PausedByUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator who placed the pause.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'PausedByUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator who placed the pause.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'PausedByUserId';
    END

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'PausedReason') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'PausedReason', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Optional - operator MAY pause without entering a reason.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'PausedReason';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Optional - operator MAY pause without entering a reason.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'PausedReason';
    END

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'ResumedByUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'ResumedByUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL while pause is open. NOT required to match PausedByUserId - paused LOTs cross shift / operator boundaries.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'ResumedByUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL while pause is open. NOT required to match PausedByUserId - paused LOTs cross shift / operator boundaries.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'ResumedByUserId';
    END

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'ResumedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'ResumedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL while pause is open.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'ResumedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL while pause is open.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'ResumedAt';
    END

    IF COL_LENGTH(N'[Lots].[PauseEvent]', N'ResumedRemarks') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[PauseEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[PauseEvent]'), N'ResumedRemarks', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Optional resume note.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'ResumedRemarks';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Optional resume note.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'PauseEvent',
                         @level2type = N'COLUMN', @level2name = N'ResumedRemarks';
    END
END
GO

-- Lots.AimShipperIdPool
IF OBJECT_ID(N'[Lots].[AimShipperIdPool]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9h (UJ-04 - AIM Shipper ID local pool). Local buffer of pre-fetched Honda AIM Shipper IDs. A background Gateway script (Arc 2 Phase 7) calls AIM.GetNextNumber to keep the pool topped up; Container_Complete claims one row FIFO, synchronously, inside its own transaction - sub-millisecond, never blocked on AIM. AIM IDs attach to Lots.Container only - never to sub-assemblies, sub-LOTs, or any other entity. Honda treats every issued ID as permanently consumed; once ConsumedAt is set the row stays terminal regardless of any downstream container void / re-pack (the new container at re-pack draws a fresh ID from the pool). Honda does not expire IDs - no TTL column.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'AimShipperIdPool';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9h (UJ-04 - AIM Shipper ID local pool). Local buffer of pre-fetched Honda AIM Shipper IDs. A background Gateway script (Arc 2 Phase 7) calls AIM.GetNextNumber to keep the pool topped up; Container_Complete claims one row FIFO, synchronously, inside its own transaction - sub-millisecond, never blocked on AIM. AIM IDs attach to Lots.Container only - never to sub-assemblies, sub-LOTs, or any other entity. Honda treats every issued ID as permanently consumed; once ConsumedAt is set the row stays terminal regardless of any downstream container void / re-pack (the new container at re-pack draws a fresh ID from the pool). Honda does not expire IDs - no TTL column.',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'AimShipperIdPool';

    IF COL_LENGTH(N'[Lots].[AimShipperIdPool]', N'AimShipperId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimShipperIdPool]'), N'AimShipperId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The Honda-issued shipper ID returned by AIM.GetNextNumber. UNIQUE protects against double-INSERT under topup-script retries.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'AimShipperId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The Honda-issued shipper ID returned by AIM.GetNextNumber. UNIQUE protects against double-INSERT under topup-script retries.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'AimShipperId';
    END

    IF COL_LENGTH(N'[Lots].[AimShipperIdPool]', N'FetchedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimShipperIdPool]'), N'FetchedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'When AIM gave this ID to us. Drives FIFO ordering at claim time.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'FetchedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'When AIM gave this ID to us. Drives FIFO ordering at claim time.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'FetchedAt';
    END

    IF COL_LENGTH(N'[Lots].[AimShipperIdPool]', N'FetchedInterfaceLogId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimShipperIdPool]'), N'FetchedInterfaceLogId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Provenance - points at the exact AIM call that issued this ID.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'FetchedInterfaceLogId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Provenance - points at the exact AIM call that issued this ID.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'FetchedInterfaceLogId';
    END

    IF COL_LENGTH(N'[Lots].[AimShipperIdPool]', N'ConsumedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimShipperIdPool]'), N'ConsumedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL = available in the pool. Non-NULL = permanently consumed.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'ConsumedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL = available in the pool. Non-NULL = permanently consumed.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'ConsumedAt';
    END

    IF COL_LENGTH(N'[Lots].[AimShipperIdPool]', N'ConsumedByContainerId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimShipperIdPool]'), N'ConsumedByContainerId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The container that claimed this ID. NULL ConsumedAt NULL.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'ConsumedByContainerId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The container that claimed this ID. NULL ConsumedAt NULL.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'ConsumedByContainerId';
    END

    IF COL_LENGTH(N'[Lots].[AimShipperIdPool]', N'ConsumedByUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimShipperIdPool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimShipperIdPool]'), N'ConsumedByUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The operator whose closing-container action consumed this ID. NULL ConsumedAt NULL.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'ConsumedByUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The operator whose closing-container action consumed this ID. NULL ConsumedAt NULL.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimShipperIdPool',
                         @level2type = N'COLUMN', @level2name = N'ConsumedByUserId';
    END
END
GO

-- Lots.AimPoolConfig
IF OBJECT_ID(N'[Lots].[AimPoolConfig]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9h (UJ-04 - AIM Pool configuration). Single-row table holding the operator-configurable thresholds for the AIM Shipper ID pool. The Configuration Tool exposes these via Lots.AimPoolConfig_Get / _Update. Single-row enforced via CHECK (Id = 1).',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'AimPoolConfig';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9h (UJ-04 - AIM Pool configuration). Single-row table holding the operator-configurable thresholds for the AIM Shipper ID pool. The Configuration Tool exposes these via Lots.AimPoolConfig_Get / _Update. Single-row enforced via CHECK (Id = 1).',
                     @level0type = N'SCHEMA', @level0name = N'Lots',
                     @level1type = N'TABLE',  @level1name = N'AimPoolConfig';

    IF COL_LENGTH(N'[Lots].[AimPoolConfig]', N'Id') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimPoolConfig]'), N'Id', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Always 1. Single-row table.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'Id';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Always 1. Single-row table.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'Id';
    END

    IF COL_LENGTH(N'[Lots].[AimPoolConfig]', N'TargetBufferDepth') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimPoolConfig]'), N'TargetBufferDepth', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The desired pool depth - topup script refills toward this value.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'TargetBufferDepth';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The desired pool depth - topup script refills toward this value.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'TargetBufferDepth';
    END

    IF COL_LENGTH(N'[Lots].[AimPoolConfig]', N'TopupThreshold') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimPoolConfig]'), N'TopupThreshold', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Topup script triggers when AvailableCount < TopupThreshold.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'TopupThreshold';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Topup script triggers when AvailableCount < TopupThreshold.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'TopupThreshold';
    END

    IF COL_LENGTH(N'[Lots].[AimPoolConfig]', N'AlarmWarningDepth') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimPoolConfig]'), N'AlarmWarningDepth', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Supervisor wallboard tile turns yellow when AvailableCount < AlarmWarningDepth.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'AlarmWarningDepth';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Supervisor wallboard tile turns yellow when AvailableCount < AlarmWarningDepth.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'AlarmWarningDepth';
    END

    IF COL_LENGTH(N'[Lots].[AimPoolConfig]', N'AlarmCriticalDepth') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimPoolConfig]'), N'AlarmCriticalDepth', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Supervisor alarm + IT notification fires when AvailableCount < AlarmCriticalDepth.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'AlarmCriticalDepth';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Supervisor alarm + IT notification fires when AvailableCount < AlarmCriticalDepth.',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'AlarmCriticalDepth';
    END

    IF COL_LENGTH(N'[Lots].[AimPoolConfig]', N'Id') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Lots].[AimPoolConfig]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Lots].[AimPoolConfig]'), N'Id', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'AlarmWarningDepth',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'Id';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'AlarmWarningDepth',
                         @level0type = N'SCHEMA', @level0name = N'Lots',
                         @level1type = N'TABLE',  @level1name = N'AimPoolConfig',
                         @level2type = N'COLUMN', @level2name = N'Id';
    END
END
GO

-- Workorder.WorkOrderStatus
IF OBJECT_ID(N'[Workorder].[WorkOrderStatus]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Workorder].[WorkOrderStatus]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderStatus]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrderStatus]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Created, InProgress, Completed, Cancelled',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderStatus',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Created, InProgress, Completed, Cancelled',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderStatus',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Workorder.ScrapSource
IF OBJECT_ID(N'[Workorder].[ScrapSource]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[ScrapSource]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table distinguishing the two scrap entry paths surfaced in the legacy Flexware Lot Details screen: Inventory (scrapping unallocated stock on a LOT) vs Location (scrapping in-process material at a specific workstation). Added v1.8 (OI-20). Seeded at migration time.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ScrapSource';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table distinguishing the two scrap entry paths surfaced in the legacy Flexware Lot Details screen: Inventory (scrapping unallocated stock on a LOT) vs Location (scrapping in-process material at a specific workstation). Added v1.8 (OI-20). Seeded at migration time.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ScrapSource';

    IF COL_LENGTH(N'[Workorder].[ScrapSource]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ScrapSource]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ScrapSource]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Inventory, Location',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ScrapSource',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Inventory, Location',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ScrapSource',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Workorder.OperationStatus
IF OBJECT_ID(N'[Workorder].[OperationStatus]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Workorder].[OperationStatus]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[OperationStatus]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[OperationStatus]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Pending, InProgress, Completed, Skipped',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'OperationStatus',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pending, InProgress, Completed, Skipped',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'OperationStatus',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Workorder.WorkOrderType
IF OBJECT_ID(N'[Workorder].[WorkOrderType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table. Added in v1.7 (Phase B); seed corrected in v1.9b (2026-04-24) per OI-07. Serves as a future hook - new WO type rows can be INSERTed without schema change when MPP scopes separate Demand (planned PM) and Maintenance (emergency) engines.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'WorkOrderType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table. Added in v1.7 (Phase B); seed corrected in v1.9b (2026-04-24) per OI-07. Serves as a future hook - new WO type rows can be INSERTed without schema change when MPP scopes separate Demand (planned PM) and Maintenance (emergency) engines.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'WorkOrderType';

    IF COL_LENGTH(N'[Workorder].[WorkOrderType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrderType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Production (the only active code in MVP)',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Production (the only active code in MVP)',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Workorder.WorkOrder
IF OBJECT_ID(N'[Workorder].[WorkOrder]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrder]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Auto-generated internal work order. Operators never see this. The table carries WorkOrderTypeId (discriminator FK -> WorkOrderType, defaults to the single-seeded Production row) and ToolId (nullable FK -> Tools.Tool, schema hook for FUTURE Maintenance WOs - unpopulated in MVP).',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'WorkOrder';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Auto-generated internal work order. Operators never see this. The table carries WorkOrderTypeId (discriminator FK -> WorkOrderType, defaults to the single-seeded Production row) and ToolId (nullable FK -> Tools.Tool, schema hook for FUTURE Maintenance WOs - unpopulated in MVP).',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'WorkOrder';

    IF COL_LENGTH(N'[Workorder].[WorkOrder]', N'WoNumber') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrder]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrder]'), N'WoNumber', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'System-generated',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'WoNumber';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'System-generated',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'WoNumber';
    END

    IF COL_LENGTH(N'[Workorder].[WorkOrder]', N'WorkOrderTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrder]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrder]'), N'WorkOrderTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.7. v1.9b (2026-04-24): defaults to Production (the corrected single-seed row). FUTURE Demand / Maintenance rows are added without schema change.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'WorkOrderTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.7. v1.9b (2026-04-24): defaults to Production (the corrected single-seed row). FUTURE Demand / Maintenance rows are added without schema change.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'WorkOrderTypeId';
    END

    IF COL_LENGTH(N'[Workorder].[WorkOrder]', N'RouteTemplateId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrder]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrder]'), N'RouteTemplateId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The route version active at creation',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'RouteTemplateId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The route version active at creation',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'RouteTemplateId';
    END

    IF COL_LENGTH(N'[Workorder].[WorkOrder]', N'ToolId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrder]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrder]'), N'ToolId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.7 as a schema hook for FUTURE Maintenance WOs (targets a specific Tool). Not populated in MVP. Enforced at the proc layer when Maintenance flow activates.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.7 as a schema hook for FUTURE Maintenance WOs (targets a specific Tool). Not populated in MVP. Enforced at the proc layer when Maintenance flow activates.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrder',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
    END
END
GO

-- Workorder.WorkOrderOperation
IF OBJECT_ID(N'[Workorder].[WorkOrderOperation]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderOperation]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Individual operation execution - the actual step that happened.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'WorkOrderOperation';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Individual operation execution - the actual step that happened.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'WorkOrderOperation';

    IF COL_LENGTH(N'[Workorder].[WorkOrderOperation]', N'RouteStepId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderOperation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrderOperation]'), N'RouteStepId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The planned step',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderOperation',
                         @level2type = N'COLUMN', @level2name = N'RouteStepId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The planned step',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderOperation',
                         @level2type = N'COLUMN', @level2name = N'RouteStepId';
    END

    IF COL_LENGTH(N'[Workorder].[WorkOrderOperation]', N'LocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderOperation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrderOperation]'), N'LocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Where it actually ran',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderOperation',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Where it actually ran',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderOperation',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
    END

    IF COL_LENGTH(N'[Workorder].[WorkOrderOperation]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[WorkOrderOperation]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[WorkOrderOperation]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator who ran the operation',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderOperation',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator who ran the operation',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'WorkOrderOperation',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END
END
GO

-- Workorder.ProductionEvent
IF OBJECT_ID(N'[Workorder].[ProductionEvent]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Checkpoint-shape event table. Per FRS 2.1.2 operator-driven capture: operators are not at the terminal for every shot - they log at checkpoints (checkout from die cast, check-in to trim, complete + move, quality-operation transitions). Each checkpoint fires one row carrying the cumulative counters as-of-that-moment; deltas are derived by the reader via LAG() window function over (LotId, EventAt). A missed event doesn''t compound errors - the next event carries truth.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ProductionEvent';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Checkpoint-shape event table. Per FRS 2.1.2 operator-driven capture: operators are not at the terminal for every shot - they log at checkpoints (checkout from die cast, check-in to trim, complete + move, quality-operation transitions). Each checkpoint fires one row carrying the cumulative counters as-of-that-moment; deltas are derived by the reader via LAG() window function over (LotId, EventAt). A missed event doesn''t compound errors - the next event carries truth.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ProductionEvent';

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'LotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'LotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Tool + Cavity derived via Lot.ToolId / Lot.ToolCavityId.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'LotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Tool + Cavity derived via Lot.ToolId / Lot.ToolCavityId.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'LotId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'OperationTemplateId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'OperationTemplateId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Captures the FDS-03-017a data-collection contract - what fields were required at this checkpoint. Direct FK so events remain queryable when work orders are absent (OI-07 background-only WOs).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'OperationTemplateId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Captures the FDS-03-017a data-collection contract - what fields were required at this checkpoint. Direct FK so events remain queryable when work orders are absent (OI-07 background-only WOs).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'OperationTemplateId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'WorkOrderOperationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'WorkOrderOperationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Nullable (MVP-LITE WO model).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'WorkOrderOperationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nullable (MVP-LITE WO model).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'WorkOrderOperationId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'EventAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'EventAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Checkpoint timestamp. Used with LAG() for delta derivation.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'EventAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Checkpoint timestamp. Used with LAG() for delta derivation.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'EventAt';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'ShotCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'ShotCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Cumulative shot counter at event time. Reader derives ShotsSinceLast = ShotCount - LAG(ShotCount) OVER (PARTITION BY LotId ORDER BY EventAt). Open item (per Decision 5 of the 2026-04-23 spec): may migrate to derived-from-aggregated-LOT-quantity before Arc 2 Phase 3 if the LOT-quantity aggregation proves authoritative for "shots per die" reporting. Kept nullable and provisional until resolved.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ShotCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Cumulative shot counter at event time. Reader derives ShotsSinceLast = ShotCount - LAG(ShotCount) OVER (PARTITION BY LotId ORDER BY EventAt). Open item (per Decision 5 of the 2026-04-23 spec): may migrate to derived-from-aggregated-LOT-quantity before Arc 2 Phase 3 if the LOT-quantity aggregation proves authoritative for "shots per die" reporting. Kept nullable and provisional until resolved.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ShotCount';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'ScrapCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'ScrapCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Cumulative scrap counter at event time. Delta via LAG().',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ScrapCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Cumulative scrap counter at event time. Delta via LAG().',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ScrapCount';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'ScrapSourceId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'ScrapSourceId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Populated only when this event represents a scrap action. Distinguishes scrap-from-inventory vs scrap-from-location per OI-20. NULL for non-scrap checkpoints.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ScrapSourceId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Populated only when this event represents a scrap action. Distinguishes scrap-from-inventory vs scrap-from-location per OI-20. NULL for non-scrap checkpoints.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ScrapSourceId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'WeightValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'WeightValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Captured when the operation template requires Weight (e.g., scale-driven container closure, OI-02).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'WeightValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Captured when the operation template requires Weight (e.g., scale-driven container closure, OI-02).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'WeightValue';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'WeightUomId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'WeightUomId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Required whenever WeightValue is set.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'WeightUomId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Required whenever WeightValue is set.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'WeightUomId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Who captured this event (initials-based per Phase C).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Who captured this event (initials-based per Phase C).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where the checkpoint was registered.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where the checkpoint was registered.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'Remarks') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'Remarks', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Free-text note attached to the checkpoint.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'Remarks';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Free-text note attached to the checkpoint.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'Remarks';
    END
END
GO

-- Workorder.ProductionEventValue
IF OBJECT_ID(N'[Workorder].[ProductionEventValue]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEventValue]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Child of ProductionEvent - holds any DataCollectionField value configured on the operation template but not promoted to a typed column on ProductionEvent. Lets engineering extend the data collection vocabulary without schema changes. One row per field collected for a given event.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ProductionEventValue';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Child of ProductionEvent - holds any DataCollectionField value configured on the operation template but not promoted to a typed column on ProductionEvent. Lets engineering extend the data collection vocabulary without schema changes. One row per field collected for a given event.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ProductionEventValue';

    IF COL_LENGTH(N'[Workorder].[ProductionEventValue]', N'DataCollectionFieldId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEventValue]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEventValue]'), N'DataCollectionFieldId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Which field this value satisfies',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'DataCollectionFieldId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Which field this value satisfies',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'DataCollectionFieldId';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEventValue]', N'Value') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEventValue]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEventValue]'), N'Value', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'String representation (canonical storage)',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'Value';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'String representation (canonical storage)',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'Value';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEventValue]', N'NumericValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEventValue]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEventValue]'), N'NumericValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Populated when the field is numeric - enables range queries without parsing Value',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'NumericValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Populated when the field is numeric - enables range queries without parsing Value',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'NumericValue';
    END

    IF COL_LENGTH(N'[Workorder].[ProductionEventValue]', N'UomId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEventValue]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEventValue]'), N'UomId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Required when the field is a measurement',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'UomId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Required when the field is a measurement',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEventValue',
                         @level2type = N'COLUMN', @level2name = N'UomId';
    END
END
GO

-- Workorder.ConsumptionEvent
IF OBJECT_ID(N'[Workorder].[ConsumptionEvent]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[ConsumptionEvent]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Records which source LOTs were consumed to produce output.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ConsumptionEvent';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Records which source LOTs were consumed to produce output.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'ConsumptionEvent';

    IF COL_LENGTH(N'[Workorder].[ConsumptionEvent]', N'SourceLotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ConsumptionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ConsumptionEvent]'), N'SourceLotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'What was consumed',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'SourceLotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'What was consumed',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'SourceLotId';
    END

    IF COL_LENGTH(N'[Workorder].[ConsumptionEvent]', N'ProducedLotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ConsumptionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ConsumptionEvent]'), N'ProducedLotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Output LOT - the primary consumption target for machining renames and assembly-out (the minted finished-good LOT).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'ProducedLotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Output LOT - the primary consumption target for machining renames and assembly-out (the minted finished-good LOT).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'ProducedLotId';
    END

    IF COL_LENGTH(N'[Workorder].[ConsumptionEvent]', N'ProducedContainerId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ConsumptionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ConsumptionEvent]'), N'ProducedContainerId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Output container (secondary/denormalized; the Container is retained as the wrapper but consumption targets ProducedLotId).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'ProducedContainerId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Output container (secondary/denormalized; the Container is retained as the wrapper but consumption targets ProducedLotId).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'ProducedContainerId';
    END

    IF COL_LENGTH(N'[Workorder].[ConsumptionEvent]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ConsumptionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ConsumptionEvent]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator who scanned the consumption',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator who scanned the consumption',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END

    IF COL_LENGTH(N'[Workorder].[ConsumptionEvent]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ConsumptionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ConsumptionEvent]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ConsumptionEvent',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END
END
GO

-- Workorder.RejectEvent
IF OBJECT_ID(N'[Workorder].[RejectEvent]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[RejectEvent]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Detailed reject/scrap records.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'RejectEvent';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Detailed reject/scrap records.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'RejectEvent';

    IF COL_LENGTH(N'[Workorder].[RejectEvent]', N'ChargeToArea') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[RejectEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[RejectEvent]'), N'ChargeToArea', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Area responsible for the reject',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'RejectEvent',
                         @level2type = N'COLUMN', @level2name = N'ChargeToArea';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Area responsible for the reject',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'RejectEvent',
                         @level2type = N'COLUMN', @level2name = N'ChargeToArea';
    END

    IF COL_LENGTH(N'[Workorder].[RejectEvent]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[RejectEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[RejectEvent]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator who recorded the reject',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'RejectEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator who recorded the reject',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'RejectEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END
END
GO

-- Workorder.DieCastContribution
IF OBJECT_ID(N'[Workorder].[DieCastContribution]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added migration 0045 (2026-07-29) - Die Cast per-cavity Open -> accumulate -> release lifecycle. Per-shift net-good ledger for an Open die-cast basket LOT. Each row is one shift-output submission at a die-cast press: the operator enters a die-wide gross shot count, the system computes per-cavity good (gross - scrap - shot-losses, see Workorder.DieCast_GetShiftOutputBreakdown), and Workorder.DieCastShiftOutput_Record writes one DieCastContribution row per contributing LOT with the net-good delta. Append-only - never updated or deleted; Lots.Lot.PieceCount is the running total, DieCastContribution is the audit trail of how it got there (also the source of the Contribution stream on Lot_GetAttributeHistory). Scrap is recorded separately and additively in Workorder.RejectEvent (die-cast ScrapIsAdditive = 1, migration 0042) - it is never written to this table and never decrements PieceCount.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'DieCastContribution';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added migration 0045 (2026-07-29) - Die Cast per-cavity Open -> accumulate -> release lifecycle. Per-shift net-good ledger for an Open die-cast basket LOT. Each row is one shift-output submission at a die-cast press: the operator enters a die-wide gross shot count, the system computes per-cavity good (gross - scrap - shot-losses, see Workorder.DieCast_GetShiftOutputBreakdown), and Workorder.DieCastShiftOutput_Record writes one DieCastContribution row per contributing LOT with the net-good delta. Append-only - never updated or deleted; Lots.Lot.PieceCount is the running total, DieCastContribution is the audit trail of how it got there (also the source of the Contribution stream on Lot_GetAttributeHistory). Scrap is recorded separately and additively in Workorder.RejectEvent (die-cast ScrapIsAdditive = 1, migration 0042) - it is never written to this table and never decrements PieceCount.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'DieCastContribution';

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'LotId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'LotId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The Open (or since-released) die-cast basket LOT this contribution was credited to.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'LotId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The Open (or since-released) die-cast basket LOT this contribution was credited to.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'LotId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'ShiftId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'ShiftId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The shift the output is reported against. Nullable - a contribution recorded outside a resolvable shift window still posts (time-decoupled entry per the design spec 3).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'ShiftId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The shift the output is reported against. Nullable - a contribution recorded outside a resolvable shift window still posts (time-decoupled entry per the design spec 3).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'ShiftId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'PieceDelta') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'PieceDelta', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Net-good pieces added to the LOT by this submission. Never negative - corrections are a new contribution row, not an update.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'PieceDelta';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Net-good pieces added to the LOT by this submission. Never negative - corrections are a new contribution row, not an update.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'PieceDelta';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator who submitted the shift output.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator who submitted the shift output.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where the submission was made.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where the submission was made.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'CellLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'CellLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The PRESS. Added migration 0061. Load-bearing for the shot-reading chain: both watermarks are scoped by it, so a die moved to another press is a different counter space and a changeover to another die on the same press has different ToolCavity rows - both reset the chain with no special-casing.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'CellLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The PRESS. Added migration 0061. Load-bearing for the shot-reading chain: both watermarks are scoped by it, so a die moved to another press is a different counter space and a changeover to another die on the same press has different ToolCavity rows - both reset the chain with no special-casing.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'CellLocationId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastContribution]', N'ShotCounterReading') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastContribution]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastContribution]'), N'ShotCounterReading', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added migration 0073 (2026-09-09) - shot-reading chain. The press-counter reading at which this ledger row was taken. The press counter resets each shift, so the number the operator types is a READING, not an increment; a basket''s credit is (reading - the cavity''s watermark). Both watermarks derive from this one column - Workorder.ufn_CavityShotWatermark scoped (ToolCavityId, ShiftId, CellLocationId) for the per-basket credit, Workorder.ufn_DieShotWatermark scoped (ToolId, ShiftId, CellLocationId) for the Tools.Tool.ShotCount increment. NULL means "recorded before migration 0073"; 0073 backfilled every such row as a running sum of PieceDelta per (cavity, shift, press).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'ShotCounterReading';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added migration 0073 (2026-09-09) - shot-reading chain. The press-counter reading at which this ledger row was taken. The press counter resets each shift, so the number the operator types is a READING, not an increment; a basket''s credit is (reading - the cavity''s watermark). Both watermarks derive from this one column - Workorder.ufn_CavityShotWatermark scoped (ToolCavityId, ShiftId, CellLocationId) for the per-basket credit, Workorder.ufn_DieShotWatermark scoped (ToolId, ShiftId, CellLocationId) for the Tools.Tool.ShotCount increment. NULL means "recorded before migration 0073"; 0073 backfilled every such row as a running sum of PieceDelta per (cavity, shift, press).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastContribution',
                         @level2type = N'COLUMN', @level2name = N'ShotCounterReading';
    END
END
GO

-- Workorder.DieCastCounterAnchor
IF OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added migration 0074 (2026-09-10) - die cast counter anchor (spec docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md). An operator''s declaration of the TRUE press-counter reading for a die on a press in a shift.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added migration 0074 (2026-09-10) - die cast counter anchor (spec docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md). An operator''s declaration of the TRUE press-counter reading for a die on a press in a shift.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor';

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'ToolId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'ToolId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The die the declaration is about.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The die the declaration is about.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'ShiftId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'ShiftId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The shift it applies to. NOT NULL (unlike DieCastContribution.ShiftId) - the press counter resets per shift, so an anchor outside a shift has no counter space to anchor.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'ShiftId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The shift it applies to. NOT NULL (unlike DieCastContribution.ShiftId) - the press counter resets per shift, so an anchor outside a shift has no counter space to anchor.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'ShiftId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'CellLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'CellLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The PRESS - the same three-part scope key the watermarks use.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'CellLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The PRESS - the same three-part scope key the watermarks use.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'CellLocationId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'DeclaredReading') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'DeclaredReading', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'What the press counter actually reads. Deliberately un-guarded against going backwards - declaring a lower number is the entire point, and a monotonic guard here would reintroduce the wall inside the tool built to get past it.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'DeclaredReading';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'What the press counter actually reads. Deliberately un-guarded against going backwards - declaring a lower number is the entire point, and a monotonic guard here would reintroduce the wall inside the tool built to get past it.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'DeclaredReading';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'ReasonId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'ReasonId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Why the counter moved.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'ReasonId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Why the counter moved.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'ReasonId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'Note') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'Note', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Free text; required when the reason is Other (enforced in Workorder.DieCastCounterAnchor_Record).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'Note';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Free text; required when the reason is Other (enforced in Workorder.DieCastCounterAnchor_Record).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'Note';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Who declared it. Any signed-in operator - no AD elevation: they are the only person who can see the press counter, and gating on a supervisor strands a night shift at a wall.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Who declared it. Any signed-in operator - no AD elevation: they are the only person who can see the press counter, and gating on a supervisor strands a night shift at a wall.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchor]', N'EventAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchor]'), N'EventAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Both watermark functions compare contribution EventAt against this.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'EventAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Both watermark functions compare contribution EventAt against this.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchor',
                         @level2type = N'COLUMN', @level2name = N'EventAt';
    END
END
GO

-- Workorder.DieCastCounterAnchorReason
IF OBJECT_ID(N'[Workorder].[DieCastCounterAnchorReason]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchorReason]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added migration 0074 (2026-09-10). Read-only code table - why a press counter had to be re-anchored. Code-table backed per repo convention: no free-text reason, no magic integers.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchorReason';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added migration 0074 (2026-09-10). Read-only code table - why a press counter had to be re-anchored. Code-table backed per repo convention: no free-text reason, no magic integers.',
                     @level0type = N'SCHEMA', @level0name = N'Workorder',
                     @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchorReason';

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchorReason]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchorReason]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchorReason]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator-facing label; drives the reason dropdown.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchorReason',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator-facing label; drives the reason dropdown.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchorReason',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Workorder].[DieCastCounterAnchorReason]', N'SortOrder') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[DieCastCounterAnchorReason]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[DieCastCounterAnchorReason]'), N'SortOrder', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Dropdown order (CounterReset first - the commonest case).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchorReason',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Dropdown order (CounterReset first - the commonest case).',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'DieCastCounterAnchorReason',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
    END
END
GO

-- Quality.DefectCode
IF OBJECT_ID(N'[Quality].[DefectCode]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Quality].[DefectCode]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'~170 reject/defect reason codes.',
                     @level0type = N'SCHEMA', @level0name = N'Quality',
                     @level1type = N'TABLE',  @level1name = N'DefectCode';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'~170 reject/defect reason codes.',
                     @level0type = N'SCHEMA', @level0name = N'Quality',
                     @level1type = N'TABLE',  @level1name = N'DefectCode';

    IF COL_LENGTH(N'[Quality].[DefectCode]', N'AreaLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[DefectCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[DefectCode]'), N'AreaLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Area (ISA-95 Area, organizational grouping)',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'DefectCode',
                         @level2type = N'COLUMN', @level2name = N'AreaLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Area (ISA-95 Area, organizational grouping)',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'DefectCode',
                         @level2type = N'COLUMN', @level2name = N'AreaLocationId';
    END

    IF COL_LENGTH(N'[Quality].[DefectCode]', N'IsExcused') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[DefectCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[DefectCode]'), N'IsExcused', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Affects OEE quality calculation',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'DefectCode',
                         @level2type = N'COLUMN', @level2name = N'IsExcused';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Affects OEE quality calculation',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'DefectCode',
                         @level2type = N'COLUMN', @level2name = N'IsExcused';
    END
END
GO

-- Quality.QualitySpec
IF OBJECT_ID(N'[Quality].[QualitySpec]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[QualitySpec]', N'DeprecatedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySpec]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySpec]'), N'DeprecatedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Header-level soft-delete - lets a spec be deprecated at the header level. Added migration 0017.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpec',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Header-level soft-delete - lets a spec be deprecated at the header level. Added migration 0017.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpec',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
    END

    IF COL_LENGTH(N'[Quality].[QualitySpec]', N'DeprecatedByUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySpec]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySpec]'), N'DeprecatedByUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Who deprecated the spec. Added migration 0017.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpec',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedByUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Who deprecated the spec. Added migration 0017.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpec',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedByUserId';
    END
END
GO

-- Quality.QualitySpecAttribute
IF OBJECT_ID(N'[Quality].[QualitySpecAttribute]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[QualitySpecAttribute]', N'Uom') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySpecAttribute]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySpecAttribute]'), N'Uom', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Legacy free-text UoM. Superseded by UomId for Config Tool editing; retained for back-compat.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpecAttribute',
                         @level2type = N'COLUMN', @level2name = N'Uom';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Legacy free-text UoM. Superseded by UomId for Config Tool editing; retained for back-compat.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpecAttribute',
                         @level2type = N'COLUMN', @level2name = N'Uom';
    END

    IF COL_LENGTH(N'[Quality].[QualitySpecAttribute]', N'UomId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySpecAttribute]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySpecAttribute]'), N'UomId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added migration 0017 - replaces free-text Uom usage by the Config Tool QualitySpec editor.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpecAttribute',
                         @level2type = N'COLUMN', @level2name = N'UomId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added migration 0017 - replaces free-text Uom usage by the Config Tool QualitySpec editor.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySpecAttribute',
                         @level2type = N'COLUMN', @level2name = N'UomId';
    END
END
GO

-- Quality.QualitySample
IF OBJECT_ID(N'[Quality].[QualitySample]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[QualitySample]', N'QualitySpecVersionId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySample]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySample]'), N'QualitySpecVersionId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Version active at time of sampling',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySample',
                         @level2type = N'COLUMN', @level2name = N'QualitySpecVersionId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Version active at time of sampling',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySample',
                         @level2type = N'COLUMN', @level2name = N'QualitySpecVersionId';
    END

    IF COL_LENGTH(N'[Quality].[QualitySample]', N'SampleTriggerCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySample]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySample]'), N'SampleTriggerCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'What triggered this sample',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySample',
                         @level2type = N'COLUMN', @level2name = N'SampleTriggerCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'What triggered this sample',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySample',
                         @level2type = N'COLUMN', @level2name = N'SampleTriggerCodeId';
    END

    IF COL_LENGTH(N'[Quality].[QualitySample]', N'InspectionResultCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualitySample]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualitySample]'), N'InspectionResultCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Pass/Fail outcome',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySample',
                         @level2type = N'COLUMN', @level2name = N'InspectionResultCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pass/Fail outcome',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualitySample',
                         @level2type = N'COLUMN', @level2name = N'InspectionResultCodeId';
    END
END
GO

-- Quality.QualityResult
IF OBJECT_ID(N'[Quality].[QualityResult]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[QualityResult]', N'MeasuredValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualityResult]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualityResult]'), N'MeasuredValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Canonical string storage of the measured value, parsed per QualitySpecAttribute.DataType.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualityResult',
                         @level2type = N'COLUMN', @level2name = N'MeasuredValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Canonical string storage of the measured value, parsed per QualitySpecAttribute.DataType.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualityResult',
                         @level2type = N'COLUMN', @level2name = N'MeasuredValue';
    END

    IF COL_LENGTH(N'[Quality].[QualityResult]', N'NumericValue') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualityResult]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualityResult]'), N'NumericValue', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9p. Numeric shadow of MeasuredValue, populated when the attribute is numeric - enables indexable range / SPC / Cpk queries over measured results without parsing MeasuredValue. Mirrors Workorder.ProductionEventValue.NumericValue. NULL for non-numeric (string / boolean) attributes; the Arc 2 write proc sets it when QualitySpecAttribute.DataType {Integer, Decimal}. Cheap to add now (table is Arc 2-deferred, unbuilt); painful to retrofit onto a 20M+ row table later.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualityResult',
                         @level2type = N'COLUMN', @level2name = N'NumericValue';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9p. Numeric shadow of MeasuredValue, populated when the attribute is numeric - enables indexable range / SPC / Cpk queries over measured results without parsing MeasuredValue. Mirrors Workorder.ProductionEventValue.NumericValue. NULL for non-numeric (string / boolean) attributes; the Arc 2 write proc sets it when QualitySpecAttribute.DataType {Integer, Decimal}. Cheap to add now (table is Arc 2-deferred, unbuilt); painful to retrofit onto a 20M+ row table later.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualityResult',
                         @level2type = N'COLUMN', @level2name = N'NumericValue';
    END
END
GO

-- Quality.QualityAttachment
IF OBJECT_ID(N'[Quality].[QualityAttachment]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[QualityAttachment]', N'FileType') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[QualityAttachment]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[QualityAttachment]'), N'FileType', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'CSV, XLSX, PDF, PNG, JPG',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualityAttachment',
                         @level2type = N'COLUMN', @level2name = N'FileType';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'CSV, XLSX, PDF, PNG, JPG',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'QualityAttachment',
                         @level2type = N'COLUMN', @level2name = N'FileType';
    END
END
GO

-- Quality.InspectionResultCode
IF OBJECT_ID(N'[Quality].[InspectionResultCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[InspectionResultCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[InspectionResultCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[InspectionResultCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Pass, Fail',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'InspectionResultCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pass, Fail',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'InspectionResultCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Quality.SampleTriggerCode
IF OBJECT_ID(N'[Quality].[SampleTriggerCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[SampleTriggerCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[SampleTriggerCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[SampleTriggerCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'ShiftStart, DieChange, ToolChange, FirstPiece, LastPiece, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'SampleTriggerCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ShiftStart, DieChange, ToolChange, FirstPiece, LastPiece, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'SampleTriggerCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Quality.HoldTypeCode
IF OBJECT_ID(N'[Quality].[HoldTypeCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[HoldTypeCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[HoldTypeCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[HoldTypeCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Quality, CustomerComplaint, Precautionary',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldTypeCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Quality, CustomerComplaint, Precautionary',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldTypeCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Quality.DispositionCode
IF OBJECT_ID(N'[Quality].[DispositionCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[DispositionCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[DispositionCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[DispositionCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Pending, UseAsIs, Rework, Scrap, ReturnToVendor',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'DispositionCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pending, UseAsIs, Rework, Scrap, ReturnToVendor',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'DispositionCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Quality.NonConformance
IF OBJECT_ID(N'[Quality].[NonConformance]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Quality].[NonConformance]', N'DispositionCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[NonConformance]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[NonConformance]'), N'DispositionCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Current disposition',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'NonConformance',
                         @level2type = N'COLUMN', @level2name = N'DispositionCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Current disposition',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'NonConformance',
                         @level2type = N'COLUMN', @level2name = N'DispositionCodeId';
    END

    IF COL_LENGTH(N'[Quality].[NonConformance]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[NonConformance]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[NonConformance]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'NonConformance',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'NonConformance',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END
END
GO

-- Quality.HoldEvent
IF OBJECT_ID(N'[Quality].[HoldEvent]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Quality].[HoldEvent]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'A hold placed on a LOT. Same lifecycle pattern as DowntimeEvent - created on placement, updated on release. Active holds have ReleasedAt IS NULL.',
                     @level0type = N'SCHEMA', @level0name = N'Quality',
                     @level1type = N'TABLE',  @level1name = N'HoldEvent';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'A hold placed on a LOT. Same lifecycle pattern as DowntimeEvent - created on placement, updated on release. Active holds have ReleasedAt IS NULL.',
                     @level0type = N'SCHEMA', @level0name = N'Quality',
                     @level1type = N'TABLE',  @level1name = N'HoldEvent';

    IF COL_LENGTH(N'[Quality].[HoldEvent]', N'NonConformanceId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[HoldEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[HoldEvent]'), N'NonConformanceId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Nullable - holds can be precautionary',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldEvent',
                         @level2type = N'COLUMN', @level2name = N'NonConformanceId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nullable - holds can be precautionary',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldEvent',
                         @level2type = N'COLUMN', @level2name = N'NonConformanceId';
    END

    IF COL_LENGTH(N'[Quality].[HoldEvent]', N'HoldTypeCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[HoldEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[HoldEvent]'), N'HoldTypeCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Quality, CustomerComplaint, Precautionary',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldEvent',
                         @level2type = N'COLUMN', @level2name = N'HoldTypeCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Quality, CustomerComplaint, Precautionary',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldEvent',
                         @level2type = N'COLUMN', @level2name = N'HoldTypeCodeId';
    END

    IF COL_LENGTH(N'[Quality].[HoldEvent]', N'ReleasedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Quality].[HoldEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Quality].[HoldEvent]'), N'ReleasedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL while hold is active',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldEvent',
                         @level2type = N'COLUMN', @level2name = N'ReleasedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL while hold is active',
                         @level0type = N'SCHEMA', @level0name = N'Quality',
                         @level1type = N'TABLE',  @level1name = N'HoldEvent',
                         @level2type = N'COLUMN', @level2name = N'ReleasedAt';
    END
END
GO

-- OEE.DowntimeReasonType
IF OBJECT_ID(N'[OEE].[DowntimeReasonType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only, seeded in migration 0009. 6 fixed rows.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'DowntimeReasonType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only, seeded in migration 0009. 6 fixed rows.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'DowntimeReasonType';

    IF COL_LENGTH(N'[OEE].[DowntimeReasonType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeReasonType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Equipment, Miscellaneous, Mold, Quality, Setup, Unscheduled',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Equipment, Miscellaneous, Mold, Quality, Setup, Unscheduled',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- OEE.DowntimeReasonCode
IF OBJECT_ID(N'[OEE].[DowntimeReasonCode]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonCode]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'~353 active seed rows from downtime_reason_codes.csv (DC=86, MS=239, TS=25). Loaded via Oee.DowntimeReasonCode_BulkLoadFromSeed.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'~353 active seed rows from downtime_reason_codes.csv (DC=86, MS=239, TS=25). Loaded via Oee.DowntimeReasonCode_BulkLoadFromSeed.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode';

    IF COL_LENGTH(N'[OEE].[DowntimeReasonCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeReasonCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Generated as {DeptCode}-{NNNN} (e.g., DC-0003) by the bulk-load proc from the CSV''s DeptCode + zero-padded ReasonId. Engineering-created codes are free-form.',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Generated as {DeptCode}-{NNNN} (e.g., DC-0003) by the bulk-load proc from the CSV''s DeptCode + zero-padded ReasonId. Engineering-created codes are free-form.',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeReasonCode]', N'AreaLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeReasonCode]'), N'AreaLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Area (organizational grouping)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'AreaLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Area (organizational grouping)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'AreaLocationId';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeReasonCode]', N'DowntimeReasonTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeReasonCode]'), N'DowntimeReasonTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL allowed - CSV rows with missing TypeDesc load as NULL and engineering backfills via _Update before go-live',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'DowntimeReasonTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL allowed - CSV rows with missing TypeDesc load as NULL and engineering backfills via _Update before go-live',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'DowntimeReasonTypeId';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeReasonCode]', N'DowntimeSourceCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeReasonCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeReasonCode]'), N'DowntimeSourceCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'CSV carries no source column; always NULL at initial load',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'DowntimeSourceCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'CSV carries no source column; always NULL at initial load',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeReasonCode',
                         @level2type = N'COLUMN', @level2name = N'DowntimeSourceCodeId';
    END
END
GO

-- OEE.ShiftSchedule
IF OBJECT_ID(N'[OEE].[ShiftSchedule]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[OEE].[ShiftSchedule]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Named shift patterns (First Shift 6a-2p M-F, Second Shift 2p-10p, Weekend OT, etc.).',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'ShiftSchedule';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Named shift patterns (First Shift 6a-2p M-F, Second Shift 2p-10p, Weekend OT, etc.).',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'ShiftSchedule';

    IF COL_LENGTH(N'[OEE].[ShiftSchedule]', N'EndTime') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[ShiftSchedule]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[ShiftSchedule]'), N'EndTime', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Shift spans midnight when EndTime < StartTime (runtime handles this)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'ShiftSchedule',
                         @level2type = N'COLUMN', @level2name = N'EndTime';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Shift spans midnight when EndTime < StartTime (runtime handles this)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'ShiftSchedule',
                         @level2type = N'COLUMN', @level2name = N'EndTime';
    END

    IF COL_LENGTH(N'[OEE].[ShiftSchedule]', N'DaysOfWeekBitmask') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[ShiftSchedule]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[ShiftSchedule]'), N'DaysOfWeekBitmask', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64. Mon-Fri = 31; Sat+Sun = 96.',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'ShiftSchedule',
                         @level2type = N'COLUMN', @level2name = N'DaysOfWeekBitmask';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64. Mon-Fri = 31; Sat+Sun = 96.',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'ShiftSchedule',
                         @level2type = N'COLUMN', @level2name = N'DaysOfWeekBitmask';
    END
END
GO

-- OEE.Shift
IF OBJECT_ID(N'[OEE].[Shift]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[OEE].[Shift]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Runtime shift instances - written by Arc 2 (plant-floor shift controller) when a scheduled shift starts. The Config Tool only reads via Oee.Shift_List for admin visibility.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'Shift';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Runtime shift instances - written by Arc 2 (plant-floor shift controller) when a scheduled shift starts. The Config Tool only reads via Oee.Shift_List for admin visibility.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'Shift';

    IF COL_LENGTH(N'[OEE].[Shift]', N'ActualEnd') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[Shift]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[Shift]'), N'ActualEnd', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL while the shift is active',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'Shift',
                         @level2type = N'COLUMN', @level2name = N'ActualEnd';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL while the shift is active',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'Shift',
                         @level2type = N'COLUMN', @level2name = N'ActualEnd';
    END
END
GO

-- OEE.DowntimeSourceCode
IF OBJECT_ID(N'[OEE].[DowntimeSourceCode]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[OEE].[DowntimeSourceCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeSourceCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeSourceCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Manual, PLC',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeSourceCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Manual, PLC',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeSourceCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- OEE.DowntimeEvent
IF OBJECT_ID(N'[OEE].[DowntimeEvent]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Append-only. Never overwrite started_at.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'DowntimeEvent';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Append-only. Never overwrite started_at.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'DowntimeEvent';

    IF COL_LENGTH(N'[OEE].[DowntimeEvent]', N'LocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeEvent]'), N'LocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Machine',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Machine',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeEvent]', N'DowntimeReasonCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeEvent]'), N'DowntimeReasonCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'May be assigned later',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'DowntimeReasonCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'May be assigned later',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'DowntimeReasonCodeId';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeEvent]', N'EndedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeEvent]'), N'EndedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL while event is open',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'EndedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL while event is open',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'EndedAt';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeEvent]', N'DowntimeSourceCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeEvent]'), N'DowntimeSourceCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'How this event was recorded',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'DowntimeSourceCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'How this event was recorded',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'DowntimeSourceCodeId';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeEvent]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeEvent]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Operator who recorded / acknowledged the event (NULL for PLC-driven events without operator action)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operator who recorded / acknowledged the event (NULL for PLC-driven events without operator action)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END

    IF COL_LENGTH(N'[OEE].[DowntimeEvent]', N'ShotCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[DowntimeEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[DowntimeEvent]'), N'ShotCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Die cast warm-up/setup shot count (when reason_type = Setup)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'ShotCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Die cast warm-up/setup shot count (when reason_type = Setup)',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'DowntimeEvent',
                         @level2type = N'COLUMN', @level2name = N'ShotCount';
    END
END
GO

-- OEE.OeeSnapshot
IF OBJECT_ID(N'[OEE].[OeeSnapshot]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[OEE].[OeeSnapshot]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Materialized OEE per machine per shift. Derivative, not system of record.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'OeeSnapshot';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Materialized OEE per machine per shift. Derivative, not system of record.',
                     @level0type = N'SCHEMA', @level0name = N'OEE',
                     @level1type = N'TABLE',  @level1name = N'OeeSnapshot';

    IF COL_LENGTH(N'[OEE].[OeeSnapshot]', N'LocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[OeeSnapshot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[OeeSnapshot]'), N'LocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Machine',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'OeeSnapshot',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Machine',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'OeeSnapshot',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
    END

    IF COL_LENGTH(N'[OEE].[OeeSnapshot]', N'Availability') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[OeeSnapshot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[OeeSnapshot]'), N'Availability', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'0.0000 - 1.0000',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'OeeSnapshot',
                         @level2type = N'COLUMN', @level2name = N'Availability';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'0.0000 - 1.0000',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'OeeSnapshot',
                         @level2type = N'COLUMN', @level2name = N'Availability';
    END

    IF COL_LENGTH(N'[OEE].[OeeSnapshot]', N'Oee') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[OEE].[OeeSnapshot]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[OEE].[OeeSnapshot]'), N'Oee', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'availability x performance x quality_rate',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'OeeSnapshot',
                         @level2type = N'COLUMN', @level2name = N'Oee';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'availability x performance x quality_rate',
                         @level0type = N'SCHEMA', @level0name = N'OEE',
                         @level1type = N'TABLE',  @level1name = N'OeeSnapshot',
                         @level2type = N'COLUMN', @level2name = N'Oee';
    END
END
GO

-- Tools.ToolType
IF OBJECT_ID(N'[Tools].[ToolType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Polymorphic kinds. Read-only in MVP - seeded at migration time, no CRUD procs. Follows the precedent set by Location.LocationType / Location.LocationTypeDefinition.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Polymorphic kinds. Read-only in MVP - seeded at migration time, no CRUD procs. Follows the precedent set by Location.LocationType / Location.LocationTypeDefinition.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolType';

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Die, Cutter, Jig, Gauge, AssemblyFixture, TrimTool',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Die, Cutter, Jig, Gauge, AssemblyFixture, TrimTool',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display name',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Icon') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Icon', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Perspective tree component icon (matches LocationTypeDefinition.Icon pattern; NULL at deployment, populated via Config Tool)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Icon';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Perspective tree component icon (matches LocationTypeDefinition.Icon pattern; NULL at deployment, populated via Config Tool)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Icon';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'HasCavities') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'HasCavities', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'ToolCavity rows are only valid for Tools whose type has this flag set',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'HasCavities';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ToolCavity rows are only valid for Tools whose type has this flag set',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'HasCavities';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'CompatibleLocationTypeDefinitionId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'CompatibleLocationTypeDefinitionId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v1.9o (migration 0018). The Cell-kind a tool of this type may mount on - drives the Mount-to-Cell dropdown filter (Tools.Tool_ListCompatibleCells). NON-NULL restricts the dropdown to that single cell kind; NULL = no restriction (all Cell-tier Locations). One-to-one by design - a tool type maps to at most one cell kind. Seeded Die -> DieCastMachine; all other types NULL until their flows activate.',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'CompatibleLocationTypeDefinitionId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v1.9o (migration 0018). The Cell-kind a tool of this type may mount on - drives the Mount-to-Cell dropdown filter (Tools.Tool_ListCompatibleCells). NON-NULL restricts the dropdown to that single cell kind; NULL = no restriction (all Cell-tier Locations). One-to-one by design - a tool type maps to at most one cell kind. Seeded Die -> DieCastMachine; all other types NULL until their flows activate.',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'CompatibleLocationTypeDefinitionId';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'SortOrder') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'SortOrder', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'UI ordering',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'UI ordering',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'DeprecatedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'DeprecatedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Soft delete',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Soft delete',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Notes',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Notes',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Die') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Die', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Dies used on die cast machines. CompatibleLocationTypeDefinitionId -> DieCastMachine (seeded v1.9o).',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Die';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Dies used on die cast machines. CompatibleLocationTypeDefinitionId -> DieCastMachine (seeded v1.9o).',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Die';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Cutter') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Cutter', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Tool heads / inserts on CNC machines',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Cutter';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Tool heads / inserts on CNC machines',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Cutter';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Jig') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Jig', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Fixtures on assembly stations',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Jig';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Fixtures on assembly stations',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Jig';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'Gauge') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'Gauge', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Measurement tools',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Gauge';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Measurement tools',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'Gauge';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'AssemblyFixture') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'AssemblyFixture', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Trim-shop and assembly fixtures',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'AssemblyFixture';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Trim-shop and assembly fixtures',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'AssemblyFixture';
    END

    IF COL_LENGTH(N'[Tools].[ToolType]', N'TrimTool') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolType]'), N'TrimTool', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Trim-specific tooling',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'TrimTool';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Trim-specific tooling',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolType',
                         @level2type = N'COLUMN', @level2name = N'TrimTool';
    END
END
GO

-- Tools.ToolAttributeDefinition
IF OBJECT_ID(N'[Tools].[ToolAttributeDefinition]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Attribute schema per tool type. Mirrors Location.LocationAttributeDefinition.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Attribute schema per tool type. Mirrors Location.LocationAttributeDefinition.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition';

    IF COL_LENGTH(N'[Tools].[ToolAttributeDefinition]', N'ToolTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttributeDefinition]'), N'ToolTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Which kind this attribute applies to',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'ToolTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Which kind this attribute applies to',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'ToolTypeId';
    END

    IF COL_LENGTH(N'[Tools].[ToolAttributeDefinition]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttributeDefinition]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Attribute code (e.g., CycleTimeSec, Tonnage, InsertCount)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Attribute code (e.g., CycleTimeSec, Tonnage, InsertCount)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Tools].[ToolAttributeDefinition]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttributeDefinition]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Display label',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display label',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Tools].[ToolAttributeDefinition]', N'DataType') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttributeDefinition]'), N'DataType', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'String, Integer, Decimal, Boolean, Date (matches LocationAttributeDefinition.DataType values)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DataType';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'String, Integer, Decimal, Boolean, Date (matches LocationAttributeDefinition.DataType values)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DataType';
    END

    IF COL_LENGTH(N'[Tools].[ToolAttributeDefinition]', N'SortOrder') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttributeDefinition]'), N'SortOrder', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Up/down arrow ordering - no drag-and-drop per UI convention',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Up/down arrow ordering - no drag-and-drop per UI convention',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
    END

    IF COL_LENGTH(N'[Tools].[ToolAttributeDefinition]', N'DeprecatedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttributeDefinition]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttributeDefinition]'), N'DeprecatedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Soft delete',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Soft delete',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttributeDefinition',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
    END
END
GO

-- Tools.Tool
IF OBJECT_ID(N'[Tools].[Tool]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Concrete tools. System of record for tool identity.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'Tool';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Concrete tools. System of record for tool identity.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'Tool';

    IF COL_LENGTH(N'[Tools].[Tool]', N'ToolTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'ToolTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Polymorphic type',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'ToolTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Polymorphic type',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'ToolTypeId';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Die number, cutter ID, etc. (e.g., DC-042)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Die number, cutter ID, etc. (e.g., DC-042)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'Name') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'Name', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Human-friendly name',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'Name';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Human-friendly name',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'Name';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'DieRankId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'DieRankId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Die-type only; NULL for all other types. Application-level validation enforces this - no CHECK because the "die-type only" rule needs a join',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'DieRankId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Die-type only; NULL for all other types. Application-level validation enforces this - no CHECK because the "die-type only" rule needs a join',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'DieRankId';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'StatusCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'StatusCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Active / UnderRepair / Scrapped / Retired',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'StatusCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Active / UnderRepair / Scrapped / Retired',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'StatusCodeId';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'ShotCount') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'ShotCount', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v2.2 (migration 0050). Materialized lifetime shot counter. Live-incremented by Workorder.DieCastShiftOutput_Record (v1.2) - no event ledger, no reconcile job. Per-physical-asset state, not configuration: Tool_Duplicate resets it to 0, and no proc exposes a setter (a cross-database import necessarily lands 0).',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'ShotCount';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v2.2 (migration 0050). Materialized lifetime shot counter. Live-incremented by Workorder.DieCastShiftOutput_Record (v1.2) - no event ledger, no reconcile job. Per-physical-asset state, not configuration: Tool_Duplicate resets it to 0, and no proc exposes a setter (a cross-database import necessarily lands 0).',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'ShotCount';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'ShotLimit') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'ShotLimit', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Added v2.2 (migration 0050). Optional design life - shots before rebuild. Configuration, not a counter: set via Tools.Tool_Update, carried by Tool_Duplicate. NULL = no limit, and every derived field (remaining / percent / near / over) is NULL-safe in Tools.ufn_ShotStatus.',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'ShotLimit';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Added v2.2 (migration 0050). Optional design life - shots before rebuild. Configuration, not a counter: set via Tools.Tool_Update, carried by Tool_Duplicate. NULL = no limit, and every derived field (remaining / percent / near / over) is NULL-safe in Tools.ufn_ShotStatus.',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'ShotLimit';
    END

    IF COL_LENGTH(N'[Tools].[Tool]', N'DeprecatedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[Tool]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[Tool]'), N'DeprecatedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Soft delete - separate from StatusCode = Retired (Retired is the business state; DeprecatedAt is the row-lifecycle state)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Soft delete - separate from StatusCode = Retired (Retired is the business state; DeprecatedAt is the row-lifecycle state)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'Tool',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
    END
END
GO

-- Tools.ToolAttribute
IF OBJECT_ID(N'[Tools].[ToolAttribute]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttribute]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Attribute values. Mirrors Location.LocationAttribute.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolAttribute';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Attribute values. Mirrors Location.LocationAttribute.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolAttribute';

    IF COL_LENGTH(N'[Tools].[ToolAttribute]', N'Value') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAttribute]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAttribute]'), N'Value', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Stored as text; interpreted per definition''s DataType',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttribute',
                         @level2type = N'COLUMN', @level2name = N'Value';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Stored as text; interpreted per definition''s DataType',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAttribute',
                         @level2type = N'COLUMN', @level2name = N'Value';
    END
END
GO

-- Tools.ToolCavity
IF OBJECT_ID(N'[Tools].[ToolCavity]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavity]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Child of Tool. Only valid for Tools whose ToolType.HasCavities = 1 - application-level validation enforces, no CHECK.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolCavity';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Child of Tool. Only valid for Tools whose ToolType.HasCavities = 1 - application-level validation enforces, no CHECK.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolCavity';

    IF COL_LENGTH(N'[Tools].[ToolCavity]', N'ToolId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavity]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolCavity]'), N'ToolId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Parent die',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Parent die',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'ToolId';
    END

    IF COL_LENGTH(N'[Tools].[ToolCavity]', N'CavityCode') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavity]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolCavity]'), N'CavityCode', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Per-part cavity identifier: 1-4 lowercase letters (a, b, c...). A 12-cavity family die casting four parts carries four cavities called a, one per part - which is how MPP names them ("6MA EX 1 cavity a"). Immutable once saved. Replaced the die-wide integer ordinal in migration 0076.',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'CavityCode';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Per-part cavity identifier: 1-4 lowercase letters (a, b, c...). A 12-cavity family die casting four parts carries four cavities called a, one per part - which is how MPP names them ("6MA EX 1 cavity a"). Immutable once saved. Replaced the die-wide integer ordinal in migration 0076.',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'CavityCode';
    END

    IF COL_LENGTH(N'[Tools].[ToolCavity]', N'StatusCodeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavity]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolCavity]'), N'StatusCodeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Active / Closed / Scrapped',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'StatusCodeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Active / Closed / Scrapped',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'StatusCodeId';
    END

    IF COL_LENGTH(N'[Tools].[ToolCavity]', N'Description') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavity]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolCavity]'), N'Description', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Per-cavity notes (e.g., "small porosity tendency")',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'Description';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Per-cavity notes (e.g., "small porosity tendency")',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'Description';
    END

    IF COL_LENGTH(N'[Tools].[ToolCavity]', N'DeprecatedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavity]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolCavity]'), N'DeprecatedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Soft delete',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Soft delete',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavity',
                         @level2type = N'COLUMN', @level2name = N'DeprecatedAt';
    END
END
GO

-- Tools.ToolAssignment
IF OBJECT_ID(N'[Tools].[ToolAssignment]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolAssignment]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Append-only check-in / out history. A Tool can be mounted on a Cell; release closes the row by setting ReleasedAt.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolAssignment';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Append-only check-in / out history. A Tool can be mounted on a Cell; release closes the row by setting ReleasedAt.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolAssignment';

    IF COL_LENGTH(N'[Tools].[ToolAssignment]', N'CellLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAssignment]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAssignment]'), N'CellLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Cell the tool is mounted on (application validates the Location is Cell-tier)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'CellLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Cell the tool is mounted on (application validates the Location is Cell-tier)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'CellLocationId';
    END

    IF COL_LENGTH(N'[Tools].[ToolAssignment]', N'ReleasedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAssignment]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAssignment]'), N'ReleasedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'NULL = currently mounted',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'ReleasedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'NULL = currently mounted',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'ReleasedAt';
    END

    IF COL_LENGTH(N'[Tools].[ToolAssignment]', N'AssignedByUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAssignment]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAssignment]'), N'AssignedByUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Supervisor who mounted (elevated action per FDS-04-007)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'AssignedByUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Supervisor who mounted (elevated action per FDS-04-007)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'AssignedByUserId';
    END

    IF COL_LENGTH(N'[Tools].[ToolAssignment]', N'ReleasedByUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolAssignment]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolAssignment]'), N'ReleasedByUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Supervisor who released (elevated action per FDS-04-007)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'ReleasedByUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Supervisor who released (elevated action per FDS-04-007)',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolAssignment',
                         @level2type = N'COLUMN', @level2name = N'ReleasedByUserId';
    END
END
GO

-- Tools.ToolStatusCode
IF OBJECT_ID(N'[Tools].[ToolStatusCode]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolStatusCode]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table. Seeded at migration time.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolStatusCode';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table. Seeded at migration time.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolStatusCode';

    IF COL_LENGTH(N'[Tools].[ToolStatusCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolStatusCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolStatusCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Active / UnderRepair / Scrapped / Retired',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Active / UnderRepair / Scrapped / Retired',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Tools.ToolCavityStatusCode
IF OBJECT_ID(N'[Tools].[ToolCavityStatusCode]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavityStatusCode]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Read-only code table. Seeded at migration time.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolCavityStatusCode';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Read-only code table. Seeded at migration time.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'ToolCavityStatusCode';

    IF COL_LENGTH(N'[Tools].[ToolCavityStatusCode]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[ToolCavityStatusCode]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[ToolCavityStatusCode]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Active / Closed / Scrapped',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavityStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Active / Closed / Scrapped',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'ToolCavityStatusCode',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Tools.DieRank
IF OBJECT_ID(N'[Tools].[DieRank]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[DieRank]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Code table. Ships empty - MPP Quality owes the authoritative ranking scheme (the 2026-04-20 meeting proposed A-E but MPP hasn''t confirmed).',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'DieRank';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Code table. Ships empty - MPP Quality owes the authoritative ranking scheme (the 2026-04-20 meeting proposed A-E but MPP hasn''t confirmed).',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'DieRank';

    IF COL_LENGTH(N'[Tools].[DieRank]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[DieRank]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[DieRank]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Engineering populates via Config Tool once MPP Quality delivers',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'DieRank',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Engineering populates via Config Tool once MPP Quality delivers',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'DieRank',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END

    IF COL_LENGTH(N'[Tools].[DieRank]', N'SortOrder') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Tools].[DieRank]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Tools].[DieRank]'), N'SortOrder', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Up/down arrow ordering',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'DieRank',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Up/down arrow ordering',
                         @level0type = N'SCHEMA', @level0name = N'Tools',
                         @level1type = N'TABLE',  @level1name = N'DieRank',
                         @level2type = N'COLUMN', @level2name = N'SortOrder';
    END
END
GO

-- Tools.DieRankCompatibility
IF OBJECT_ID(N'[Tools].[DieRankCompatibility]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Tools].[DieRankCompatibility]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Junction. Ships empty - MPP Quality owes the compatibility matrix.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'DieRankCompatibility';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Junction. Ships empty - MPP Quality owes the compatibility matrix.',
                     @level0type = N'SCHEMA', @level0name = N'Tools',
                     @level1type = N'TABLE',  @level1name = N'DieRankCompatibility';
END
GO

-- Audit.LogSeverity
IF OBJECT_ID(N'[Audit].[LogSeverity]', 'U') IS NOT NULL
BEGIN

    IF COL_LENGTH(N'[Audit].[LogSeverity]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[LogSeverity]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[LogSeverity]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'ERROR, WARNING, INFO',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'LogSeverity',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ERROR, WARNING, INFO',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'LogSeverity',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Audit.LogEventType
IF OBJECT_ID(N'[Audit].[LogEventType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Audit].[LogEventType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Normalized vocabulary for what happened. Shared across all log tables.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'LogEventType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Normalized vocabulary for what happened. Shared across all log tables.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'LogEventType';

    IF COL_LENGTH(N'[Audit].[LogEventType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[LogEventType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[LogEventType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'LotCreated, LotMoved, ProductionRecorded, HoldPlaced, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'LogEventType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'LotCreated, LotMoved, ProductionRecorded, HoldPlaced, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'LogEventType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Audit.LogEntityType
IF OBJECT_ID(N'[Audit].[LogEntityType]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Audit].[LogEntityType]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Normalized vocabulary for what was affected. Shared across operation_log and config_log.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'LogEntityType';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Normalized vocabulary for what was affected. Shared across operation_log and config_log.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'LogEntityType';

    IF COL_LENGTH(N'[Audit].[LogEntityType]', N'Code') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[LogEntityType]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[LogEntityType]'), N'Code', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'LOT, CONTAINER, WORK_ORDER, ITEM, LOCATION, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'LogEntityType',
                         @level2type = N'COLUMN', @level2name = N'Code';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'LOT, CONTAINER, WORK_ORDER, ITEM, LOCATION, etc.',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'LogEntityType',
                         @level2type = N'COLUMN', @level2name = N'Code';
    END
END
GO

-- Audit.OperationLog
IF OBJECT_ID(N'[Audit].[OperationLog]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Audit].[OperationLog]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Every shop-floor action.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'OperationLog';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Every shop-floor action.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'OperationLog';

    IF COL_LENGTH(N'[Audit].[OperationLog]', N'TerminalLocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[OperationLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[OperationLog]'), N'TerminalLocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'OperationLog',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Terminal where action was performed',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'OperationLog',
                         @level2type = N'COLUMN', @level2name = N'TerminalLocationId';
    END

    IF COL_LENGTH(N'[Audit].[OperationLog]', N'LocationId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[OperationLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[OperationLog]'), N'LocationId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Machine/location context',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'OperationLog',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Machine/location context',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'OperationLog',
                         @level2type = N'COLUMN', @level2name = N'LocationId';
    END

    IF COL_LENGTH(N'[Audit].[OperationLog]', N'EntityId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[OperationLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[OperationLog]'), N'EntityId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'PK of the affected entity',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'OperationLog',
                         @level2type = N'COLUMN', @level2name = N'EntityId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'PK of the affected entity',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'OperationLog',
                         @level2type = N'COLUMN', @level2name = N'EntityId';
    END
END
GO

-- Audit.ConfigLog
IF OBJECT_ID(N'[Audit].[ConfigLog]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Audit].[ConfigLog]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Engineering and admin configuration changes.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'ConfigLog';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Engineering and admin configuration changes.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'ConfigLog';

    IF COL_LENGTH(N'[Audit].[ConfigLog]', N'Changes') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[ConfigLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[ConfigLog]'), N'Changes', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'JSON or structured diff',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'ConfigLog',
                         @level2type = N'COLUMN', @level2name = N'Changes';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'JSON or structured diff',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'ConfigLog',
                         @level2type = N'COLUMN', @level2name = N'Changes';
    END
END
GO

-- Audit.InterfaceLog
IF OBJECT_ID(N'[Audit].[InterfaceLog]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Audit].[InterfaceLog]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'External system communications.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'InterfaceLog';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'External system communications.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'InterfaceLog';

    IF COL_LENGTH(N'[Audit].[InterfaceLog]', N'SystemName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[InterfaceLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[InterfaceLog]'), N'SystemName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'AIM, PLC, MACOLA, INTELEX',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'InterfaceLog',
                         @level2type = N'COLUMN', @level2name = N'SystemName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'AIM, PLC, MACOLA, INTELEX',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'InterfaceLog',
                         @level2type = N'COLUMN', @level2name = N'SystemName';
    END

    IF COL_LENGTH(N'[Audit].[InterfaceLog]', N'Direction') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[InterfaceLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[InterfaceLog]'), N'Direction', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Inbound, OUTBOUND',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'InterfaceLog',
                         @level2type = N'COLUMN', @level2name = N'Direction';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Inbound, OUTBOUND',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'InterfaceLog',
                         @level2type = N'COLUMN', @level2name = N'Direction';
    END

    IF COL_LENGTH(N'[Audit].[InterfaceLog]', N'RequestPayload') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[InterfaceLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[InterfaceLog]'), N'RequestPayload', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'When high-fidelity logging enabled',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'InterfaceLog',
                         @level2type = N'COLUMN', @level2name = N'RequestPayload';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'When high-fidelity logging enabled',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'InterfaceLog',
                         @level2type = N'COLUMN', @level2name = N'RequestPayload';
    END
END
GO

-- Audit.FailureLog
IF OBJECT_ID(N'[Audit].[FailureLog]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                 AND minor_id = 0
                 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Records attempted but rejected stored procedure calls - parameter validation failures, business rule violations, FK mismatches, and unexpected exceptions caught by a CATCH handler. Complements ConfigLog and OperationLog: those tables record what succeeded, FailureLog records what was attempted and blocked. Used for UX improvement (surface common rejection reasons), abuse detection, and root-cause analysis.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'FailureLog';
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Records attempted but rejected stored procedure calls - parameter validation failures, business rule violations, FK mismatches, and unexpected exceptions caught by a CATCH handler. Complements ConfigLog and OperationLog: those tables record what succeeded, FailureLog records what was attempted and blocked. Used for UX improvement (surface common rejection reasons), abuse detection, and root-cause analysis.',
                     @level0type = N'SCHEMA', @level0name = N'Audit',
                     @level1type = N'TABLE',  @level1name = N'FailureLog';

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'AttemptedAt') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'AttemptedAt', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'When the call was attempted',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'AttemptedAt';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'When the call was attempted',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'AttemptedAt';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'AppUserId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'AppUserId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Who attempted the action',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Who attempted the action',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'AppUserId';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'LogEntityTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'LogEntityTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'What kind of entity (e.g., Location, Item, Bom)',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'LogEntityTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'What kind of entity (e.g., Location, Item, Bom)',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'LogEntityTypeId';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'EntityId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'EntityId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Target entity Id; NULL for Create attempts where no Id exists yet',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'EntityId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Target entity Id; NULL for Create attempts where no Id exists yet',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'EntityId';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'LogEventTypeId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'LogEventTypeId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'What action was attempted (Created, Updated, Deprecated, etc.)',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'LogEventTypeId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'What action was attempted (Created, Updated, Deprecated, etc.)',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'LogEventTypeId';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'FailureReason') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'FailureReason', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The @Message value returned to the caller',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'FailureReason';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The @Message value returned to the caller',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'FailureReason';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'ProcedureName') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'ProcedureName', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Fully-qualified proc name (e.g., Location.Location_Create)',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'ProcedureName';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Fully-qualified proc name (e.g., Location.Location_Create)',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'ProcedureName';
    END

    IF COL_LENGTH(N'[Audit].[FailureLog]', N'AttemptedParameters') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Audit].[FailureLog]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Audit].[FailureLog]'), N'AttemptedParameters', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'JSON snapshot of the input parameters for debugging',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'AttemptedParameters';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'JSON snapshot of the input parameters for debugging',
                         @level0type = N'SCHEMA', @level0name = N'Audit',
                         @level1type = N'TABLE',  @level1name = N'FailureLog',
                         @level2type = N'COLUMN', @level2name = N'AttemptedParameters';
    END
END
GO

-- 69 table descriptions, 314 column descriptions
