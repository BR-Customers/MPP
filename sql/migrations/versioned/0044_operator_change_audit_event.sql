-- =============================================
-- Migration:   0044_operator_change_audit_event.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-23
-- Description: Audit LogEventType seed for terminal operator handoff logging
--              ("any terminal user id change needs to be logged"). Additive lookup
--              row only; no schema change. Entity type AppUser (Id 16) already exists.
--                * 75 OperatorChanged - the active operator at a terminal changed
--                  (A -> B) or first signed in. Lands in Audit.OperationLog.
--              Next-free Id verified 75 (max seeded = 74 DowntimeVoided; 70 is a gap).
-- =============================================

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 75 OR Code = N'OperatorChanged')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (75, N'OperatorChanged', N'Operator Changed',
         N'The active operator at a terminal changed (handoff A -> B) or first signed in. Recorded in Audit.OperationLog.');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0044_operator_change_audit_event')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0044_operator_change_audit_event',
        N'Audit LogEventType 75 OperatorChanged for terminal operator handoff logging.');
GO
