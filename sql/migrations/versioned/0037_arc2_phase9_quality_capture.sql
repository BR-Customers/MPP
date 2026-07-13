-- ============================================================
-- Migration:   0037_arc2_phase9_quality_capture.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-10
-- Description: Arc 2 Phase 9 (Quality Capture + CRT + Global Trace) per the
--              2026-07-10 reconciliation spec.
--                1. Quality.QualitySample     -- inspection header (FDS-08-011/012/013)
--                2. Quality.QualityResult     -- per-attribute result (+ NumericValue
--                   DECIMAL(18,4) indexable shadow, v1.9p)
--                3. Quality.QualityAttachment -- file metadata linked to a sample
--                   (file-upload UI is a Designer follow-up; API surface complete)
--              Reuses existing code tables: Quality.InspectionResultCode (0004,
--              Pass/Fail/Conditional) and Quality.SampleTriggerCode (0004) -- this
--              migration only ADDS the FDS-08-014 trigger rows (ids 5-9, additive):
--              ShiftStart, DieChange, ToolChange, TimeInterval, Manual.
--              CRT (FDS-10-011/012) needs NO schema: Lots.Lot.CrtActive shipped in
--              Phase 1 (0020, v1.9q); CRT is procs + audit + UI.
--              Audit seeds: LogEventType 63-66 (InspectionRecorded, CrtActivated,
--              CrtCleared, MissedCrtInspect); LogEntityType 57 (QualitySample).
--              B7 routing note: Audit.Audit_LogOperation routes only entity 'Lot'
--              to Lots.LotEventLog (code-based, not table-driven) -- entity
--              'QualitySample' therefore lands in Audit.OperationLog, which is the
--              intended route. CrtActivated/CrtCleared/MissedCrtInspect are written
--              as entity 'Lot' so they land in the 20-yr LotEventLog.
--              Idempotent, GO-separated, ASCII-only. Explicit-Id audit inserts
--              (those PKs are not identity) guarded by IF NOT EXISTS; the
--              SampleTriggerCode PK IS identity, so its adds use IDENTITY_INSERT.
-- ============================================================

-- ---- 1. Quality.QualitySample ----
IF OBJECT_ID(N'Quality.QualitySample', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.QualitySample (
        Id                     BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LotId                  BIGINT       NOT NULL,
        QualitySpecVersionId   BIGINT       NOT NULL,
        LocationId             BIGINT       NULL,
        SampleTriggerCodeId    BIGINT       NULL,
        InspectionResultCodeId BIGINT       NOT NULL,
        SampledByUserId        BIGINT       NOT NULL,
        SampledAt              DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_QualitySample_Lot         FOREIGN KEY (LotId)                  REFERENCES Lots.Lot(Id),
        CONSTRAINT FK_QualitySample_SpecVersion FOREIGN KEY (QualitySpecVersionId)   REFERENCES Quality.QualitySpecVersion(Id),
        CONSTRAINT FK_QualitySample_Location    FOREIGN KEY (LocationId)             REFERENCES Location.Location(Id),
        CONSTRAINT FK_QualitySample_Trigger     FOREIGN KEY (SampleTriggerCodeId)    REFERENCES Quality.SampleTriggerCode(Id),
        CONSTRAINT FK_QualitySample_Result      FOREIGN KEY (InspectionResultCodeId) REFERENCES Quality.InspectionResultCode(Id),
        CONSTRAINT FK_QualitySample_User        FOREIGN KEY (SampledByUserId)        REFERENCES Location.AppUser(Id)
    );

    CREATE INDEX IX_QualitySample_LotId_SampledAt ON Quality.QualitySample (LotId, SampledAt);
END
GO

-- ---- 2. Quality.QualityResult ----
IF OBJECT_ID(N'Quality.QualityResult', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.QualityResult (
        Id                     BIGINT         NOT NULL IDENTITY(1,1) PRIMARY KEY,
        QualitySampleId        BIGINT         NOT NULL,
        QualitySpecAttributeId BIGINT         NOT NULL,
        MeasuredValue          NVARCHAR(200)  NULL,
        NumericValue           DECIMAL(18,4)  NULL,   -- v1.9p indexable shadow of MeasuredValue
        IsPass                 BIT            NULL,   -- NULL = informational (optional attribute, empty)
        CONSTRAINT FK_QualityResult_Sample    FOREIGN KEY (QualitySampleId)        REFERENCES Quality.QualitySample(Id),
        CONSTRAINT FK_QualityResult_Attribute FOREIGN KEY (QualitySpecAttributeId) REFERENCES Quality.QualitySpecAttribute(Id)
    );

    CREATE INDEX IX_QualityResult_QualitySampleId ON Quality.QualityResult (QualitySampleId);
END
GO

-- ---- 3. Quality.QualityAttachment ----
IF OBJECT_ID(N'Quality.QualityAttachment', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.QualityAttachment (
        Id               BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        QualitySampleId  BIGINT        NULL,
        FileName         NVARCHAR(260) NOT NULL,
        FileType         NVARCHAR(20)  NOT NULL,
        FilePath         NVARCHAR(500) NOT NULL,
        UploadedAt       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        UploadedByUserId BIGINT        NOT NULL,
        CONSTRAINT FK_QualityAttachment_Sample FOREIGN KEY (QualitySampleId)  REFERENCES Quality.QualitySample(Id),
        CONSTRAINT FK_QualityAttachment_User   FOREIGN KEY (UploadedByUserId) REFERENCES Location.AppUser(Id)
    );

    CREATE INDEX IX_QualityAttachment_QualitySampleId ON Quality.QualityAttachment (QualitySampleId);
END
GO

-- ---- 4. Audit LogEventType seeds (63-66; not identity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 63 OR Code = N'InspectionRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (63, N'InspectionRecorded', N'Inspection Recorded', N'A quality inspection sample was recorded against a LOT.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 64 OR Code = N'CrtActivated')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (64, N'CrtActivated', N'CRT Activated', N'A Controlled Run Tag was activated on a LOT (FDS-10-011).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 65 OR Code = N'CrtCleared')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (65, N'CrtCleared', N'CRT Cleared', N'A Controlled Run Tag was cleared from a LOT (supervisor release).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 66 OR Code = N'MissedCrtInspect')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES (66, N'MissedCrtInspect', N'Missed CRT Inspection', N'A required CRT (200%) inspection was flagged as missed.');
GO

-- ---- 5. Audit LogEntityType seed (57; not identity) ----
-- Audit_LogOperation routing is code-based ('Lot' only -> LotEventLog); entity
-- 'QualitySample' falls through to Audit.OperationLog, which is the intended route.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 57 OR Code = N'QualitySample')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES (57, N'QualitySample', N'Quality Sample', N'Quality.QualitySample - inspection sample header (routes to OperationLog).');
GO

-- ---- 6. SampleTriggerCode additive rows (ids 5-9, FDS-08-014; identity PK) ----
IF NOT EXISTS (SELECT 1 FROM Quality.SampleTriggerCode WHERE Id = 5 OR Code = N'ShiftStart')
BEGIN
    SET IDENTITY_INSERT Quality.SampleTriggerCode ON;
    INSERT INTO Quality.SampleTriggerCode (Id, Code, Name) VALUES (5, N'ShiftStart', N'Shift Start');
    SET IDENTITY_INSERT Quality.SampleTriggerCode OFF;
END
GO
IF NOT EXISTS (SELECT 1 FROM Quality.SampleTriggerCode WHERE Id = 6 OR Code = N'DieChange')
BEGIN
    SET IDENTITY_INSERT Quality.SampleTriggerCode ON;
    INSERT INTO Quality.SampleTriggerCode (Id, Code, Name) VALUES (6, N'DieChange', N'Die Change');
    SET IDENTITY_INSERT Quality.SampleTriggerCode OFF;
END
GO
IF NOT EXISTS (SELECT 1 FROM Quality.SampleTriggerCode WHERE Id = 7 OR Code = N'ToolChange')
BEGIN
    SET IDENTITY_INSERT Quality.SampleTriggerCode ON;
    INSERT INTO Quality.SampleTriggerCode (Id, Code, Name) VALUES (7, N'ToolChange', N'Tool Change');
    SET IDENTITY_INSERT Quality.SampleTriggerCode OFF;
END
GO
IF NOT EXISTS (SELECT 1 FROM Quality.SampleTriggerCode WHERE Id = 8 OR Code = N'TimeInterval')
BEGIN
    SET IDENTITY_INSERT Quality.SampleTriggerCode ON;
    INSERT INTO Quality.SampleTriggerCode (Id, Code, Name) VALUES (8, N'TimeInterval', N'Time Interval');
    SET IDENTITY_INSERT Quality.SampleTriggerCode OFF;
END
GO
IF NOT EXISTS (SELECT 1 FROM Quality.SampleTriggerCode WHERE Id = 9 OR Code = N'Manual')
BEGIN
    SET IDENTITY_INSERT Quality.SampleTriggerCode ON;
    INSERT INTO Quality.SampleTriggerCode (Id, Code, Name) VALUES (9, N'Manual', N'Manual');
    SET IDENTITY_INSERT Quality.SampleTriggerCode OFF;
END
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0037_arc2_phase9_quality_capture')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0037_arc2_phase9_quality_capture',
        N'Arc 2 Phase 9: Quality.QualitySample/QualityResult/QualityAttachment (inspection recording, FDS-08-011/012/013) + SampleTriggerCode rows 5-9 (FDS-08-014) + audit seeds (LogEventType 63-66, LogEntityType 57). CRT uses the Phase-1 Lots.Lot.CrtActive hook; Global Trace is read-only (no tables).');
GO

PRINT 'Migration 0037 (Arc 2 Phase 9 quality capture + CRT + global trace seeds) applied.';
GO
