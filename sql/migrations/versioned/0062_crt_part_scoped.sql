-- =============================================
-- Migration:   0062_crt_part_scoped.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-19
-- Description: Part-scoped CRT (Controlled Run Tag), design 2026-08-19 section 4.
--              Task 1 of the part-scoped CRT feature: schema foundation only.
--
--              Parts.Item.CrtEnabled (D1) flags a part as CRT-controlled. LOTs
--              of a CrtEnabled part are marked at mint time and blocked from
--              advancing / from moving to production locations until Quality
--              clears them -- but that resolver, the guards, and the UI are
--              later tasks. This migration adds only the flag.
--
--              Location.LocationTypeDefinition.IsProductionDestination (D5a)
--              makes the movement-block's "is this a production location"
--              test DATA-driven rather than a hardcoded list of definition
--              codes baked into a proc -- a new LocationTypeDefinition
--              declares itself production or not at seed time. Seeded here
--              for the 7 known production definitions; the 8 known
--              non-production definitions are explicitly seeded to 0 for
--              clarity even though 0 is already the column default.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0062_crt_part_scoped')
BEGIN PRINT 'Migration 0062 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Parts.Item.CrtEnabled ----
IF COL_LENGTH('Parts.Item', 'CrtEnabled') IS NULL
    ALTER TABLE Parts.Item
        ADD CrtEnabled BIT NOT NULL CONSTRAINT DF_Item_CrtEnabled DEFAULT 0;
GO

-- ---- 2. Location.LocationTypeDefinition.IsProductionDestination ----
IF COL_LENGTH('Location.LocationTypeDefinition', 'IsProductionDestination') IS NULL
    ALTER TABLE Location.LocationTypeDefinition
        ADD IsProductionDestination BIT NOT NULL
            CONSTRAINT DF_LTD_IsProductionDestination DEFAULT 0;
GO

-- D5a: production-vs-not is DATA, so a new definition declares itself rather
-- than requiring a proc edit. Idempotent -- re-running re-asserts the same set.
UPDATE Location.LocationTypeDefinition
   SET IsProductionDestination = 1
 WHERE Code IN (N'DieCastMachine', N'TrimPress', N'CNCMachine',
                N'AssemblyStation', N'SerializedAssemblyLine',
                N'ProductionLine', N'ProductionArea')
   AND IsProductionDestination <> 1;

UPDATE Location.LocationTypeDefinition
   SET IsProductionDestination = 0
 WHERE Code IN (N'InspectionStation', N'InspectionLine', N'InventoryLocation',
                N'Receiving', N'SupportArea', N'Printer', N'Scale', N'Terminal')
   AND IsProductionDestination <> 0;
GO

-- ---- 3. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0062_crt_part_scoped')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0062_crt_part_scoped',
        N'Part-scoped CRT: Parts.Item.CrtEnabled and Location.LocationTypeDefinition.IsProductionDestination (+ seed).');
GO

PRINT 'Migration 0062 (crt_part_scoped) applied.';
GO
