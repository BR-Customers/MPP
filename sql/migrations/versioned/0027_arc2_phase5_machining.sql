-- ============================================================
-- Migration:   0027_arc2_phase5_machining.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-19
-- Description: Arc 2 Phase 5 (Machining) data-model deltas + seeds.
--                1. ALTER Parts.OperationTemplate ADD RequiresSubLotSplit BIT
--                   NOT NULL DEFAULT 0 (FDS v1.3 / Phased Plan v1.1). Drives the
--                   Machining OUT outbound flow: 1 => the line sublots (operator
--                   multi-destination split screen); 0 => PLC-driven auto-move
--                   (coupled) or manual whole-move (uncoupled).
--                2. Seed MachiningIn + MachiningOut Parts.OperationTemplate rows
--                   (versioned, two-state: VersionNumber=1, DeprecatedAt IS NULL =
--                   active). MachiningOut carries RequiresSubLotSplit=1 (the
--                   initial sublotting default per the Phased Plan); MachiningIn
--                   keeps the column default 0. NO OperationTemplateField children
--                   (Machining uses the promoted ProductionEvent ShotCount/
--                   ScrapCount columns, like Trim).
--                3. Seed Audit.LogEventType rows for the Phase 5 events at the
--                   next-free ids (LogEventType MAX was 41 after Phase 8; these
--                   take 42-45). LogEntityType reuses the existing ProductionEvent
--                   (machining checkpoint events) + Lot (the split) subjects -- no
--                   new LogEntityType row needed.
--
--              Idempotent, GO-separated (the ALTER needs a batch break so the new
--              column is visible to the seed). ASCII-only strings. OperationTemplate
--              seeds live in the migration (not a seed file) because they are
--              tightly coupled to the RequiresSubLotSplit ALTER. LogEventType PKs
--              are NOT identity -> explicit Id insert guarded by IF NOT EXISTS, no
--              SET IDENTITY_INSERT.
--
--              AreaLocationId is a NOT NULL FK to Location.Location; the plant
--              hierarchy is seed-loaded (011) AFTER all migrations run, so this
--              migration's OperationTemplate seed CANNOT resolve an Area by Code at
--              apply time. The seed is therefore deferred to a companion SEED file
--              (sql/seeds/026_seed_machining_operation_templates.sql) that runs
--              after 011 -- this migration only ships the ALTER + audit seeds.
--              (The audit LogEventType code table is fully migration-resident, so
--              those seeds run here.)
-- ============================================================

-- ---- 1. RequiresSubLotSplit ALTER (FDS v1.3 / Phased Plan v1.1) ----
IF COL_LENGTH(N'Parts.OperationTemplate', N'RequiresSubLotSplit') IS NULL
    ALTER TABLE Parts.OperationTemplate
        ADD RequiresSubLotSplit BIT NOT NULL
            CONSTRAINT DF_OperationTemplate_RequiresSubLotSplit DEFAULT (0);
GO

-- ---- 2. Audit seeds (explicit Id insert; LogEventType PK is not identity) ----
-- LogEventType MAX(Id) was 41 after Phase 8 (0026). Next-free = 42. Each guarded
-- by IF NOT EXISTS on Id OR Code so a re-apply is a no-op.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 42 OR Code = N'MachiningInPicked')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (42, N'MachiningInPicked', N'Machining IN Picked',
         N'A whole cast/trim LOT was picked from a Machining Cell FIFO queue, renamed via the machined-Item BOM, and consumed into a new machined LOT.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 43 OR Code = N'MachiningOutCompleted')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (43, N'MachiningOutCompleted', N'Machining OUT Completed',
         N'PLC-driven Machining OUT completion on an uncoupled line: a closing ProductionEvent was written; the LOT stays at the Cell awaiting an operator move.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 44 OR Code = N'MachiningOutAutoMoved')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (44, N'MachiningOutAutoMoved', N'Machining OUT Auto-Moved',
         N'PLC-driven Machining OUT completion on a coupled line: a closing ProductionEvent was written and the LOT auto-moved to the coupled downstream Cell (FDS-06-008).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 45 OR Code = N'MachiningOutSubLotSplit')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (45, N'MachiningOutSubLotSplit', N'Machining OUT Sub-LOT Split',
         N'Operator-driven Machining OUT on a sublotting line: a closing ProductionEvent was written and the machined LOT was split into N sub-LOTs routed to N destinations (FDS-05-009).');
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0027_arc2_phase5_machining')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0027_arc2_phase5_machining',
        N'Arc 2 Phase 5: Parts.OperationTemplate.RequiresSubLotSplit ALTER + audit seeds (LogEventType 42-45: MachiningInPicked/MachiningOutCompleted/MachiningOutAutoMoved/MachiningOutSubLotSplit). MachiningIn/MachiningOut OperationTemplate rows seeded in sql/seeds/026 (after the plant-hierarchy seed).');
GO

PRINT 'Migration 0027 (Arc 2 Phase 5 machining: RequiresSubLotSplit + audit seeds) applied.';
GO
