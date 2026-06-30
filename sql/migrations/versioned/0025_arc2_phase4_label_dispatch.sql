-- ============================================================
-- Migration:   0025_arc2_phase4_label_dispatch.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 4 label-dispatch delta (gateway-coupled; kept out of
--              0024 per the Spec-1/Spec-2 split).
--                + Lots.LotLabel.DispatchedAt DATETIME2(3) NULL (dispatch-ack ts,
--                  distinct from PrintedAt which is set at render time).
--                  PrinterName already exists (0021) -- no column add.
--                + Audit.LogEventType 36 LabelDispatched (InterfaceLog rows).
--              The @PrinterName param on LotLabel_Print/_Reprint and the new
--              LotLabel_RecordDispatch proc are repeatable migrations.
--              Idempotent (re-apply = no-op). ASCII-only strings.
-- ============================================================

IF COL_LENGTH('Lots.LotLabel', 'DispatchedAt') IS NULL
    ALTER TABLE Lots.LotLabel ADD DispatchedAt DATETIME2(3) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 36 OR Code = N'LabelDispatched')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (36, N'LabelDispatched', N'Label Dispatched', N'An LTT/label ZPL payload was dispatched to a networked printer over raw TCP (logged to InterfaceLog on every attempt).');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0025_arc2_phase4_label_dispatch')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0025_arc2_phase4_label_dispatch',
            N'Arc 2 Phase 4 label dispatch: Lots.LotLabel.DispatchedAt added; Audit.LogEventType 36 LabelDispatched. @PrinterName params on Print/Reprint + LotLabel_RecordDispatch are repeatable.');
GO

PRINT 'Migration 0025 (Arc 2 Phase 4 label dispatch) applied.';
GO
