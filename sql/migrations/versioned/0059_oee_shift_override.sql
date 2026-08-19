-- ============================================================
-- Migration: 0059_oee_shift_override.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-19
-- Description: Per-equipment shift overrides (backlog 6.1).
--
--   Oee.ShiftSchedule answers "what window does shift <S> run on day <D>"
--   PLANT-WIDE. Oee.ShiftOverride answers the same question for ONE piece of
--   equipment on ONE calendar day, and wins when present. Resolution rule
--   (Hunter, 2026-08-19): for a given day, if the equipment has an override use
--   it, otherwise fall back to the global shift.
--
--   EQUIPMENT = Location.Location. Rationale:
--     - Oee.DowntimeEvent.LocationId already FKs Location.Location, so every OEE
--       fact that exists today is already location-scoped. An override keyed to
--       anything else could not be joined to the facts it is meant to re-scale.
--     - A die cast press IS a Cell (DC1-M01 "Machine 01", LocationTypeDefinition
--       DieCastMachine, HierarchyLevel 4). Machining/Assembly downtime rolls up to
--       the WorkCenter (line) via Oee.ufn_ResolveDowntimeScope. So "a piece of
--       equipment" for OEE purposes is exactly the SCOPE location that resolver
--       returns -- a Cell for die cast, a WorkCenter for M&A.
--     - Tools.Tool is a die/mold, not equipment: it moves between presses, so a
--       shift cannot belong to it.
--   The tier is NOT enforced by a CHECK (the hierarchy is polymorphic); the
--   Create proc validates against Oee.ufn_ResolveDowntimeScope instead, so an
--   override always lines up with how downtime is already bucketed.
--
--   TIME BASIS -- LOCAL (Eastern) wall clock, matching Oee.ShiftSchedule and
--   Oee.Shift.ActualStart/ActualEnd (see OI-38: the shift subsystem stores local
--   by deliberate decision, spec 2026-07-31-shift-boundary-reconcile-design
--   sec 1.1). BusinessDate is the calendar date the shift instance STARTS on.
--     - Midnight crossing: EndTime < StartTime => the window ends on
--       BusinessDate + 1 day. A 22:00-06:00 shift on 2026-08-19 resolves to
--       2026-08-19 22:00 -> 2026-08-20 06:00. Extending it to 08:00 keeps
--       EndTime < StartTime and still lands on BusinessDate + 1.
--     - CK_ShiftOverride_NonZeroWindow forbids EndTime = StartTime, which is
--       ambiguous between a zero-length and a 24-hour window. Longest
--       expressible window is therefore 23:59:59.
--     - DST is NOT handled: a naive local window spanning the spring-forward or
--       fall-back instant is 23 or 25 hours of wall clock but 22/26 hours of
--       elapsed time. Inherited from the subsystem's local basis (OI-38);
--       called out here so it is a known limit, not an accident.
--
--   Idempotent, GO-separated, ASCII-only strings.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0059_oee_shift_override')
BEGIN PRINT 'Migration 0059 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Oee.ShiftOverride ----
IF OBJECT_ID(N'Oee.ShiftOverride', N'U') IS NULL
BEGIN
    CREATE TABLE Oee.ShiftOverride (
        Id                 BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LocationId         BIGINT        NOT NULL,   -- equipment (downtime scope location)
        ShiftScheduleId    BIGINT        NOT NULL,   -- which shift is being overridden
        BusinessDate       DATE          NOT NULL,   -- LOCAL date the shift instance starts on
        StartTime          TIME(0)       NOT NULL,   -- LOCAL wall clock
        EndTime            TIME(0)       NOT NULL,   -- LOCAL wall clock; < StartTime crosses midnight
        Reason             NVARCHAR(500) NULL,
        CreatedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_ShiftOverride_CreatedAt DEFAULT SYSUTCDATETIME(),
        CreatedByUserId    BIGINT        NOT NULL,
        UpdatedAt          DATETIME2(3)  NULL,
        UpdatedByUserId    BIGINT        NULL,
        DeprecatedAt       DATETIME2(3)  NULL,
        DeprecatedByUserId BIGINT        NULL,
        CONSTRAINT FK_ShiftOverride_Location
            FOREIGN KEY (LocationId)         REFERENCES Location.Location(Id),
        CONSTRAINT FK_ShiftOverride_Schedule
            FOREIGN KEY (ShiftScheduleId)    REFERENCES Oee.ShiftSchedule(Id),
        CONSTRAINT FK_ShiftOverride_CreatedBy
            FOREIGN KEY (CreatedByUserId)    REFERENCES Location.AppUser(Id),
        CONSTRAINT FK_ShiftOverride_UpdatedBy
            FOREIGN KEY (UpdatedByUserId)    REFERENCES Location.AppUser(Id),
        CONSTRAINT FK_ShiftOverride_DeprecatedBy
            FOREIGN KEY (DeprecatedByUserId) REFERENCES Location.AppUser(Id),
        -- EndTime = StartTime is ambiguous (zero-length vs 24h). Forbid it.
        CONSTRAINT CK_ShiftOverride_NonZeroWindow CHECK (EndTime <> StartTime)
    );

    -- The resolution rule is single-valued: at most ONE active override per
    -- (equipment, shift, day). Enforced in the engine, not only in the proc.
    CREATE UNIQUE INDEX UX_ShiftOverride_Active
        ON Oee.ShiftOverride (LocationId, ShiftScheduleId, BusinessDate)
        WHERE DeprecatedAt IS NULL;

    -- List screen: "overrides on/around date D", newest first.
    CREATE INDEX IX_ShiftOverride_Date
        ON Oee.ShiftOverride (BusinessDate DESC, LocationId)
        WHERE DeprecatedAt IS NULL;
END
GO

-- ---- 2. Audit seeds (Id-or-Code guarded; next free ids taken at build time) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'ShiftOverride')
BEGIN
    DECLARE @NextEntityId INT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@NextEntityId, N'ShiftOverride', N'Shift Override',
            N'Per-equipment adjustment of a shift window on one calendar day.');
END
GO

-- ---- 3. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0059_oee_shift_override')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0059_oee_shift_override',
        N'Oee.ShiftOverride (per-equipment per-day shift window; LocationId FK) + LogEntityType ShiftOverride. Local wall-clock basis, matching Oee.ShiftSchedule/Oee.Shift (OI-38).');
GO
PRINT 'Migration 0059 (oee_shift_override) applied.';
GO
