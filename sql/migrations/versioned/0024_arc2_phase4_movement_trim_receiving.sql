-- ============================================================
-- Migration:   0024_arc2_phase4_movement_trim_receiving.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 4 (Movement + Trim + Receiving) audit-lookup seeds.
--              Schema-free: NO tables, NO ALTERs (the six Phase 4 procs are
--              repeatable migrations; the Trim OperationTemplates are a SEED --
--              024 -- because OperationTemplate.AreaLocationId FKs the
--              seed-loaded plant hierarchy).
--                + Audit.LogEventType 34 TrimCheckpointRecorded (reserved;
--                  Trim IN currently reuses ProductionEvent_Record =>
--                  DieCastCheckpointRecorded -- see plan flag 1)
--                + Audit.LogEventType 35 TrimOutRecorded
--              No new LogEntityType (Lot / ProductionEvent / RejectEvent exist).
--              No ReceivingScan event (Receiving = Lot_Create => LotCreated).
--              Idempotent (re-apply = no-op). ASCII-only strings.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 34 OR Code = N'TrimCheckpointRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (34, N'TrimCheckpointRecorded', N'Trim Checkpoint Recorded', N'A trim-station production checkpoint was recorded (reserved; Trim IN currently records via ProductionEvent_Record).');
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 35 OR Code = N'TrimOutRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (35, N'TrimOutRecorded', N'Trim Out Recorded', N'A whole-LOT Trim OUT move into a Machining-line FIFO queue (closing checkpoint + move).');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0024_arc2_phase4_movement_trim_receiving')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0024_arc2_phase4_movement_trim_receiving',
            N'Arc 2 Phase 4 audit-lookup seeds: LogEventType 34 TrimCheckpointRecorded (reserved) + 35 TrimOutRecorded. No tables/ALTERs; procs are repeatable; Trim OperationTemplates are seed 024.');
GO

PRINT 'Migration 0024 (Arc 2 Phase 4 movement/trim/receiving audit seeds) applied.';
GO
