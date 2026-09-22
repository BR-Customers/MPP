-- ============================================================
-- Migration:   0096_trim_partial_checkpoint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Description: Trim partial checkpoint at shift end
--              (docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md).
--              1. Workorder.ProductionEvent gains ShiftId BIGINT NULL FK -> Oee.Shift.
--                 Stamped by Workorder.TrimPartial_Record (operator-picked shift) and
--                 Workorder.TrimOut_Record v1.5 (Oee.ufn_ShiftIdForInstant). Nullable:
--                 existing rows and every other writer leave it NULL; no backfill.
--                 Adding a nullable column is metadata-only, which matters because
--                 ProductionEvent is born partitioned on EventAt (0020).
--              2. LogEventType 34 TrimCheckpointRecorded stops saying "reserved".
-- ============================================================

IF COL_LENGTH(N'Workorder.ProductionEvent', N'ShiftId') IS NULL
    ALTER TABLE Workorder.ProductionEvent ADD ShiftId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ProductionEvent_Shift')
    ALTER TABLE Workorder.ProductionEvent
        ADD CONSTRAINT FK_ProductionEvent_Shift FOREIGN KEY (ShiftId) REFERENCES Oee.Shift(Id);
GO

UPDATE Audit.LogEventType
SET Description = N'A trim checkpoint was recorded without moving the LOT: a partial trim count at shift end (Workorder.TrimPartial_Record).'
WHERE Id = 34 AND Code = N'TrimCheckpointRecorded';
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0096_trim_partial_checkpoint')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0096_trim_partial_checkpoint',
            N'ProductionEvent.ShiftId (FK Oee.Shift) for the trim partial checkpoint at shift end; LogEventType 34 described.');
GO
PRINT 'Migration 0096 (trim_partial_checkpoint) applied.';
GO
