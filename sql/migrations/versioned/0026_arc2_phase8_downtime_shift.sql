-- ============================================================
-- Migration:   0026_arc2_phase8_downtime_shift.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 8 (Downtime + Shift Boundary).
--                1. Oee.DowntimeEvent (append-only event table; one-open-per-Location).
--                2. Oee.DowntimeReasonCode += StandardDurationMinutes (break durations).
--                3. Seed: Break reason type (7) + LUNCH/BREAK1/BREAK2 codes,
--                   Site-scoped, uniform durations (spec section 3.2; FDS-09-013
--                   recorded divergence -- breaks are fixed reason codes, not
--                   per-schedule config).
--                4. Audit seeds: LogEntityType 47 DowntimeEvent;
--                   LogEventType 37-41 (Downtime*/EndOfShift*/ShiftHandover*).
--              Idempotent, GO-separated (ALTER then seed needs a batch break so
--              the new column is visible). ASCII-only strings (audit-seed
--              convention). LogEventType/LogEntityType PKs are NOT identity ->
--              explicit Id insert with IF NOT EXISTS guard, no SET IDENTITY_INSERT.
-- ============================================================

-- ---- 1. Oee.DowntimeEvent ----
IF OBJECT_ID(N'Oee.DowntimeEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Oee.DowntimeEvent (
        Id                    BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LocationId            BIGINT        NOT NULL,
        DowntimeReasonCodeId  BIGINT        NULL,
        ShiftId               BIGINT        NULL,
        StartedAt             DATETIME2(3)  NOT NULL,
        EndedAt               DATETIME2(3)  NULL,
        DowntimeSourceCodeId  BIGINT        NOT NULL,
        AppUserId             BIGINT        NULL,
        ShotCount             INT           NULL,
        Remarks               NVARCHAR(500) NULL,
        CreatedAt             DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DowntimeEvent_Location FOREIGN KEY (LocationId)           REFERENCES Location.Location(Id),
        CONSTRAINT FK_DowntimeEvent_Reason   FOREIGN KEY (DowntimeReasonCodeId) REFERENCES Oee.DowntimeReasonCode(Id),
        CONSTRAINT FK_DowntimeEvent_Shift    FOREIGN KEY (ShiftId)              REFERENCES Oee.Shift(Id),
        CONSTRAINT FK_DowntimeEvent_Source   FOREIGN KEY (DowntimeSourceCodeId) REFERENCES Oee.DowntimeSourceCode(Id),
        CONSTRAINT FK_DowntimeEvent_AppUser  FOREIGN KEY (AppUserId)            REFERENCES Location.AppUser(Id)
    );

    -- B3: at most one OPEN downtime event per Location.
    CREATE UNIQUE INDEX UX_DowntimeEvent_OneOpenPerLocation
        ON Oee.DowntimeEvent (LocationId) WHERE EndedAt IS NULL;

    -- Shift availability rollup + open-event reads.
    CREATE INDEX IX_DowntimeEvent_Shift ON Oee.DowntimeEvent (ShiftId, StartedAt);
END
GO

-- ---- 2. DowntimeReasonCode delta (batch break so the column is visible to 3b) ----
IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'StandardDurationMinutes') IS NULL
    ALTER TABLE Oee.DowntimeReasonCode ADD StandardDurationMinutes INT NULL;
GO

-- ---- 3a. Break reason type (Id 7; DowntimeReasonType IS identity) ----
IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonType WHERE Code = N'Break')
BEGIN
    SET IDENTITY_INSERT Oee.DowntimeReasonType ON;
    INSERT INTO Oee.DowntimeReasonType (Id, Code, Name) VALUES (7, N'Break', N'Break');
    SET IDENTITY_INSERT Oee.DowntimeReasonType OFF;
END
GO

-- ---- 3b. Break/lunch reason codes (Site-scoped; uniform durations) ----
-- Placeholder durations (MPP seed data point): Lunch 30, Break 15/15.
DECLARE @SiteId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @BreakTypeId BIGINT = (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break');

IF @SiteId IS NOT NULL AND @BreakTypeId IS NOT NULL
    INSERT INTO Oee.DowntimeReasonCode (Code, Description, AreaLocationId, DowntimeReasonTypeId, IsExcused, StandardDurationMinutes, CreatedByUserId)
    SELECT v.Code, v.Descr, @SiteId, @BreakTypeId, 1, v.Mins, 1
    FROM (VALUES (N'LUNCH',  N'Scheduled lunch',   30),
                 (N'BREAK1', N'Scheduled break 1', 15),
                 (N'BREAK2', N'Scheduled break 2', 15)) v(Code, Descr, Mins)
    WHERE NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode rc WHERE rc.Code = v.Code);
GO

-- ---- 4. Audit seeds (explicit Id insert; these PKs are not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 47 OR Code = N'DowntimeEvent')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (47, N'DowntimeEvent', N'Downtime Event', N'Oee.DowntimeEvent - machine downtime span (manual or PLC).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 37 OR Code = N'DowntimeStarted')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (37, N'DowntimeStarted', N'Downtime Started', N'A downtime event was opened.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 38 OR Code = N'DowntimeEnded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (38, N'DowntimeEnded', N'Downtime Ended', N'A downtime event was closed.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 39 OR Code = N'DowntimeReasonAssigned')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (39, N'DowntimeReasonAssigned', N'Downtime Reason Assigned', N'A reason code was late-bound to an open downtime event (B7).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 40 OR Code = N'EndOfShiftSubmitted')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (40, N'EndOfShiftSubmitted', N'End-of-Shift Submitted', N'An operator submitted end-of-shift lunch/break time entry.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 41 OR Code = N'ShiftHandoverAcknowledged')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (41, N'ShiftHandoverAcknowledged', N'Shift Handover Acknowledged', N'An operator acknowledged the shift-end summary.');
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0026_arc2_phase8_downtime_shift')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0026_arc2_phase8_downtime_shift',
        N'Arc 2 Phase 8: Oee.DowntimeEvent + DowntimeReasonCode.StandardDurationMinutes + Break type/codes seed (Site-scoped, uniform) + audit seeds (LogEntityType 47, LogEventType 37-41).');
GO

PRINT 'Migration 0026 (Arc 2 Phase 8 downtime + shift boundary) applied.';
GO
