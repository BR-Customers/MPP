-- ============================================================
-- Migration:   0003_add_icon_to_location_type_definition.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-04-13
-- Description: Adds Icon column (NVARCHAR(100) NULL) to
--              Location.LocationTypeDefinition for Perspective
--              Tree component icon mapping, and seeds custom
--              `mpp/` icon-library paths for all 15 definitions.
--
--              Icon values are stored as full Perspective paths
--              (`mpp/<name>`) so bindings can drop them into
--              props.icon.path with no transform. The custom
--              library is shipped from `ignition/icons/mpp/`;
--              the locked sprite set lives in `mockup/icons.csv`
--              and is realized in `ignition/icons/mpp/mpp.svg`.
--              Edits flow through the Configuration Tool
--              LocationTypeDefinition frontend once built.
-- ============================================================

BEGIN TRANSACTION;

-- Guard: skip if already applied
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = '0003_add_icon_to_location_type_definition')
BEGIN
    PRINT 'Migration 0003 already applied — skipping.';
    COMMIT;
    RETURN;
END

-- == ADD COLUMN ================================================

ALTER TABLE Location.LocationTypeDefinition
    ADD Icon NVARCHAR(100) NULL;

GO

-- == SEED ICON PATHS ===========================================
-- Custom `mpp/` icon library (shipped from ignition/icons/mpp/).
-- Stored as full Perspective paths (mpp/<name>) — no transform
-- needed at binding time. Sprite ids resolve to entries in
-- `ignition/icons/mpp/mpp.svg`; locked set in `mockup/icons.csv`.

UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/account_balance'        WHERE Code = N'Organization';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/factory'                WHERE Code = N'Facility';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/workspaces'             WHERE Code = N'ProductionArea';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/engineering'            WHERE Code = N'SupportArea';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/arrow_right_alt'        WHERE Code = N'ProductionLine';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/fact_check'             WHERE Code = N'InspectionLine';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/tune'                   WHERE Code = N'Terminal';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/local_fire_department'  WHERE Code = N'DieCastMachine';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/handyman'               WHERE Code = N'CNCMachine';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/content_cut'            WHERE Code = N'TrimPress';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/handyman'               WHERE Code = N'AssemblyStation';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/qr_code_scanner'        WHERE Code = N'SerializedAssemblyLine';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/videocam'               WHERE Code = N'InspectionStation';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/inventory_2'            WHERE Code = N'InventoryLocation';
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/package_2'              WHERE Code = N'Scale';

-- == VERSION TRACKING ==========================================

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (
    '0003_add_icon_to_location_type_definition',
    'Adds Icon column to LocationTypeDefinition and seeds mpp/* icon-library paths for all 15 definitions'
);

COMMIT;
