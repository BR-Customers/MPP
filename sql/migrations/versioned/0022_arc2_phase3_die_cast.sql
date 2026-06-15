-- ============================================================
-- Migration:   0022_arc2_phase3_die_cast.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-15
-- Description: Arc 2 Phase 3 — Die Cast Operator Station foundation (SEEDS
--              ONLY). All tables are already shipped by 0020
--              (Workorder.ProductionEvent / RejectEvent, Parts.OperationTemplate
--              / OperationTemplateField, Tools.ToolCavity, Lots.Lot, etc.); this
--              migration adds ONLY the reference/lookup seeds the three Phase 3
--              procs depend on:
--
--                1. Audit.LogEntityType rows for the two event entities the
--                   ProductionEvent_Record / RejectEvent_Record audit writers
--                   reference (ProductionEvent=45, RejectEvent=46). Absent from
--                   0001/0010/0020 (verified), so added here.
--                2. Audit.LogEventType rows for the two new plant-floor events
--                   (DieCastCheckpointRecorded=32, RejectEventRecorded=33).
--                3. The 'DieCastShot' OperationTemplate (VersionNumber=1) + its
--                   OperationTemplateField children (the data-collection fields a
--                   die-cast checkpoint records).
--
--              All seeds are idempotent (guarded on a natural key). ASCII-only
--              Name/Description throughout (sqlcmd Windows-codepage mojibake
--              guard). No tables, no ALTERs.
--
-- ------------------------------------------------------------
-- AUDIT-LOOKUP Id ALLOCATION (manual Ids; reserved here, no clash with 0020):
--   Audit.LogEventType  (max existing after 0021 = 31 'LotResumed'):
--       32  DieCastCheckpointRecorded
--       33  RejectEventRecorded
--   Audit.LogEntityType (max existing after 0021 = 44 'LotGenealogy'):
--       45  ProductionEvent
--       46  RejectEvent
--
-- ------------------------------------------------------------
-- OperationTemplate THREE-STATE NOTE (verified 2026-06-15):
--   Parts.OperationTemplate (created 0006) is a TWO-state versioned entity:
--   it carries VersionNumber + CreatedAt + DeprecatedAt but NO PublishedAt
--   column (unlike Bom / RouteTemplate / QualitySpecVersion, which DO carry a
--   Draft->Published lifecycle). The Phase 3 design's "three-state
--   Draft->Published" wording does not match the shipped 0006 schema; an active
--   OperationTemplate row (DeprecatedAt IS NULL) is the published/usable state.
--   This migration therefore seeds DieCastShot at VersionNumber=1 with
--   DeprecatedAt NULL (i.e. active/published) using the columns that exist. No
--   schema change is in scope (0022 is seeds-only).
-- ============================================================


-- ============================================================
-- == Audit lookups — entity types (ProductionEvent 45, RejectEvent 46) =======
-- ============================================================
-- The Phase 3 audit writers attribute events to these entities. Routed through
-- Audit.Audit_LogOperation -> Audit.OperationLog (Workorder entities are NOT in
-- the B7 'Lot'-only LotEventLog routed set). Guarded so a re-apply is a no-op.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 45 OR Code = N'ProductionEvent')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (45, N'ProductionEvent', N'Production Event', N'Workorder.ProductionEvent — checkpoint-shape production record (cumulative shot/scrap counters).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 46 OR Code = N'RejectEvent')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (46, N'RejectEvent', N'Reject Event', N'Workorder.RejectEvent — detailed reject/scrap record against a LOT and DefectCode.');
GO


-- ============================================================
-- == Audit lookups — event types (DieCastCheckpointRecorded 32, RejectEventRecorded 33)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 32 OR Code = N'DieCastCheckpointRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (32, N'DieCastCheckpointRecorded', N'Die Cast Checkpoint Recorded', N'A die-cast operator-station production checkpoint was recorded (cumulative shot/scrap counters).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 33 OR Code = N'RejectEventRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (33, N'RejectEventRecorded', N'Reject Event Recorded', N'A reject/scrap record was recorded against a LOT (decrements available pieces; closes the LOT at zero).');
GO


-- ============================================================
-- == DieCastShot OperationTemplate -> deferred to a SEED file =================
-- ============================================================
-- Parts.OperationTemplate.AreaLocationId is a NOT NULL FK to Location.Location.
-- The plant Location hierarchy is loaded by a SEED (sql/seeds/011_seed_locations_
-- mpp_plant.sql), and the deployment pipeline runs ALL versioned migrations
-- BEFORE any seed (Reset-DevDatabase steps 4 then 6). At THIS migration's apply
-- time there are NO Location rows, so a DieCastShot insert here would either fail
-- the FK or silently no-op (no Area to bind to). The same constraint is why the
-- FALLBACK-TERMINAL Location lives in a seed, not in 0020 (see 0020 Section C).
--
-- The DieCastShot OperationTemplate (VersionNumber=1) + its OperationTemplateField
-- children therefore live in sql/seeds/022_seed_die_cast_operation_template.sql,
-- which runs after the plant-hierarchy seed and binds AreaLocationId to the first
-- active Area-tier Location. This migration owns only the location-independent
-- audit lookups above.


-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0022_arc2_phase3_die_cast')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0022_arc2_phase3_die_cast',
        N'Arc 2 Phase 3 die-cast operator station seeds: ProductionEvent/RejectEvent LogEntityType (45/46), DieCastCheckpointRecorded/RejectEventRecorded LogEventType (32/33). Location-dependent DieCastShot OperationTemplate v1 + fields live in sql/seeds/022 (seeds run after the plant-hierarchy seed). Seeds-only (all tables shipped in 0020).'
    );
GO
PRINT 'Migration 0022 (Arc 2 Phase 3 die-cast seeds) applied.';
GO
