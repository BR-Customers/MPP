-- =============================================
-- Migration:   0015_audit_add_event_type_deleted.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-05-26
-- Description:
--   Adds Audit.LogEventType row Id=21 Code='Deleted' to support hard-delete
--   audit entries on entities that may legitimately be discarded rather
--   than soft-deprecated. Initially consumed by Parts.RouteTemplate_DiscardDraft
--   (Phase 5) which hard-deletes an unpublished Draft + its steps; future
--   _DiscardDraft procs on BOM, QualitySpec, OperationTemplate will use
--   the same code.
--
--   Idempotent — the IF NOT EXISTS guard lets re-runs land cleanly.
-- =============================================

BEGIN TRANSACTION;

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'Deleted')
BEGIN
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (21, N'Deleted', N'Deleted', N'Entity was hard-deleted (e.g., DiscardDraft)');
END;

INSERT INTO dbo.SchemaVersion (MigrationId, Description) VALUES (
    '0015_audit_add_event_type_deleted',
    'Audit.LogEventType Id=21 Code=Deleted added for hard-delete audit entries (Phase 5 RouteTemplate_DiscardDraft and future siblings).'
);

COMMIT TRANSACTION;
GO
