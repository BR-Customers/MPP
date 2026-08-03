-- ============================================================
-- Migration:   0046_label_type_routing.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-28
-- Description: Dual-transport label printing (design 2026-07-28) part 1.
--                ~ Lots.PrintReasonCode Id 2 name em-dash -> ASCII hyphen. The
--                  0004 seed wrote 'Reprint - Damaged' with an em-dash, which
--                  mojibakes through sqlcmd (repo ASCII-only rule; tracked P4-7).
--
--              DEVIATION FROM TASK BRIEF: the brief's Step 3 also had this
--              migration INSERT a Location.LocationAttributeDefinition
--              'LabelTypes' row on the Printer definition (DefId 16). That
--              INSERT would fail on every fresh build: Location.LocationTypeDefinition
--              Id=16 ('Printer') is NOT created by any versioned migration --
--              it's created by the seed layer (sql/seeds/011_seed_locations_mpp_plant.sql,
--              generated from sql/seeds/gen_locations_mpp.js), which runs strictly
--              AFTER all versioned migrations in both Run-Tests.ps1 and
--              Reset-DevDatabase.ps1 (migrations -> repeatables -> seeds). A migration
--              that FKs to LocationTypeDefinitionId=16 cannot run before that row exists.
--              The existing Endpoint/Model attribute definitions on Printer (DefId 16)
--              already follow this precedent -- they live in the seed generator, not a
--              migration. 'LabelTypes' (SortOrder 3) was added there instead, alongside
--              them: sql/seeds/gen_locations_mpp.js (source), regenerated into
--              sql/seeds/011_seed_locations_mpp_plant.sql, and mirrored into
--              sql/scripts/reconcile_location_dev.sql for already-built dev DBs. This
--              migration now carries only the schema-independent, order-safe part of
--              the design (the PrintReasonCode fix) plus the SchemaVersion row.
--
--              Idempotent (re-apply = no-op). ASCII-only strings.
-- ============================================================

UPDATE Lots.PrintReasonCode
SET Name = N'Reprint - Damaged'
WHERE Id = 2 AND Name <> N'Reprint - Damaged';
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0046_label_type_routing')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0046_label_type_routing',
            N'Label-type printer routing part 1: PrintReasonCode 2 em-dash corrected to ASCII. Printer.LabelTypes attribute definition added via the seed layer (sql/seeds/gen_locations_mpp.js), not this migration -- see file header.');
GO

PRINT 'Migration 0045 (label-type routing) applied.';
GO
