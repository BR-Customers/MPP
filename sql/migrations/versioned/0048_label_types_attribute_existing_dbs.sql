-- ============================================================
-- Migration:   0048_label_types_attribute_existing_dbs.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-28
-- Description: Back-fills the Printer 'LabelTypes' LocationAttributeDefinition into
--              databases that ALREADY EXIST and are never reset (Dev today, Prod at
--              cutover).
--
--              Why this is separate from 0045: the attribute definition FKs to
--              Location.LocationTypeDefinition Id 16 ('Printer'), and that row is
--              created only by the SEED layer (sql/seeds/011_seed_locations_mpp_plant.sql,
--              generated from gen_locations_mpp.js). Reset-DevDatabase.ps1 runs versioned
--              migrations at step 4/6 but seeds at step 6/6, so on a FRESH build the FK
--              target does not exist at migration time -- which is why 0045 could not
--              carry the insert and the seed generator gained it instead.
--
--              But a seed-only home leaves existing databases stranded: they are never
--              reset, so they never re-run the seed, so they never get the attribute --
--              and label-type routing silently degrades to the default printer with no
--              error to explain it (Location.Terminal_GetPrinter falls back by design).
--
--              The EXISTS guard on DefId 16 is what makes one migration serve both:
--                * fresh build  -> DefId 16 absent at 4/6 -> skip; the seed adds both at 6/6
--                * existing DB  -> DefId 16 present        -> insert
--                * re-run       -> attribute present       -> skip
--
--              Idempotent (re-apply = no-op). ASCII-only strings.
--
--              RELATED, deliberately not deduplicated: sql/scripts/reconcile_location_dev.sql
--              carries an identical guarded INSERT (it is regenerated from
--              gen_locations_mpp.js alongside the seed). That script is MANUAL -- someone
--              has to remember to run it against a specific dev DB. This migration is the
--              AUTOMATIC path, which is what an unattended Prod cutover needs. Both are
--              guarded and idempotent, so running either or both is safe. If the attribute
--              definition is ever corrected, update the generator (which refreshes the seed
--              and the reconcile script) AND add a new forward migration -- this one is an
--              immutable historical snapshot and must not be edited after release.
-- ============================================================

IF EXISTS (SELECT 1 FROM Location.LocationTypeDefinition WHERE Id = 16)
   AND NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
                   WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'LabelTypes')
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (16, N'LabelTypes', N'NVARCHAR', 0, NULL, NULL, 3,
         N'Comma-separated Lots.LabelTypeCode codes this printer serves (Primary,Container,Master,Void). Blank = any.');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0048_label_types_attribute_existing_dbs')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0048_label_types_attribute_existing_dbs',
            N'Back-fills Printer.LabelTypes attribute definition into already-existing databases; guarded so a fresh build skips it and the seed layer supplies it instead.');
GO

PRINT 'Migration 0047 (LabelTypes back-fill for existing DBs) applied.';
GO
