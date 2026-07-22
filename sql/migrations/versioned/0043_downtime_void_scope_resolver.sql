-- ============================================================
-- Migration:   0043_downtime_void_scope_resolver.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-21
-- Description: Downtime CRUD foundation (Increment 1).
--                1. Oee.DowntimeEvent += VoidedAt / VoidedByUserId / VoidReason
--                   (soft void; append-only convention -- no hard delete).
--                2. Audit.LogEventType seeds 71-74 (Downtime reason-change / times-
--                   edit / historical / void). LogEntityType 'DowntimeEvent' (47)
--                   already exists (0026). Ids 67-70 were taken by later PLC/closure
--                   migrations, so this block starts at 71 (current max was 70).
--              The scope resolver function lives in the repeatable
--              R__Oee_ufn_ResolveDowntimeScope.sql (function = repeatable, per
--              project convention). Idempotent, GO-separated, ASCII-only.
-- ============================================================

-- ---- 1. Void columns ----
IF COL_LENGTH(N'Oee.DowntimeEvent', N'VoidedAt') IS NULL
    ALTER TABLE Oee.DowntimeEvent ADD
        VoidedAt        DATETIME2(3)  NULL,
        VoidedByUserId  BIGINT        NULL CONSTRAINT FK_DowntimeEvent_VoidedBy REFERENCES Location.AppUser(Id),
        VoidReason      NVARCHAR(500) NULL;
GO

-- ---- 2. Audit event-type seeds (explicit Id; these PKs are not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 71 OR Code = N'DowntimeReasonChanged')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (71, N'DowntimeReasonChanged', N'Downtime Reason Changed', N'A downtime event reason was changed (manager edit).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 72 OR Code = N'DowntimeTimesEdited')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (72, N'DowntimeTimesEdited', N'Downtime Times Edited', N'A downtime event start/end time was retroactively corrected.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 73 OR Code = N'DowntimeRecordedHistorical')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (73, N'DowntimeRecordedHistorical', N'Downtime Recorded (Historical)', N'A fully-past downtime event was entered after the fact.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 74 OR Code = N'DowntimeVoided')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (74, N'DowntimeVoided', N'Downtime Voided', N'A downtime event was soft-voided.');
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0043_downtime_void_scope_resolver')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0043_downtime_void_scope_resolver',
        N'Downtime CRUD: Oee.DowntimeEvent void columns + Audit.LogEventType 71-74. Resolver fn in repeatable.');
GO
PRINT 'Migration 0043 (downtime void columns + audit event-types) applied.';
GO
