-- ============================================================
-- Migration:   0110_controlled_run_results_signoff.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-13
-- Description: Super-lot (Controlled Run) pieces 2 and 3 of 6 -- a completed
--              container's tag becomes real; inspection results, a signed bulk
--              release, a deviation record and a signature record.
--
--   DO NOT DEPLOY TO PRODUCTION ON ITS OWN. Nothing in this feature deploys
--   until all six pieces are in. Specs:
--   docs/superpowers/specs/2026-10-12-controlled-run-completed-containers-design.md
--   docs/superpowers/specs/2026-10-12-controlled-run-results-and-signoff-design.md
--
--   D2  The deviation is a CHILD of the super-lot (Quality.ControlledRunDeviation).
--       The standalone Quality.NonConformance the data model once described was
--       never built and is not built here.
--   D4  A result entry is never edited. It may be VOIDED once (three columns).
--   D8  Quality.Signature is append-only and a trigger enforces it. This is the
--       first trigger in the schema, on purpose: "cannot be altered" has to be
--       true, not a convention. It THROWs (never ROLLBACKs) because it can fire
--       inside a caller's INSERT-EXEC.
--   D9  Quality screens get their own elevation window: 30 minutes idle, with
--       a separate ceiling (the existing ceiling is 30 minutes from sign-in).
--
--   The "200% inspection completed" confirmation is a FACT on the release row
--   (InspectionConfirmed, constrained to 1), not free text.
--
--   Idempotent per statement; ASCII-only (sqlcmd codepage rule).
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0110_controlled_run_results_signoff')
BEGIN PRINT 'Migration 0110 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Code rows on existing tables ----
IF NOT EXISTS (SELECT 1 FROM Quality.DispositionCode WHERE Code = N'Accepted')
    INSERT INTO Quality.DispositionCode (Code, Name) VALUES (N'Accepted', N'Accepted');
GO
IF NOT EXISTS (SELECT 1 FROM Quality.ControlledRunMemberEndReason WHERE Code = N'Released')
BEGIN
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason ON;
    INSERT INTO Quality.ControlledRunMemberEndReason (Id, Code, Name) VALUES (4, N'Released', N'Released');
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason OFF;
END
GO
IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = N'ControlledRunDeviation')
    INSERT INTO Lots.IdentifierSequence (Code, Name, Description, FormatString, StartingValue, EndingValue, LastValue)
    VALUES (N'ControlledRunDeviation', N'Deviation number', N'Quality.ControlledRunDeviation.DeviationNumber counter.', N'DV{0:D6}', 1, 999999, 0);
GO

-- ---- 2. Quality.SignatureMeaning (read-only code table) ----
IF OBJECT_ID(N'Quality.SignatureMeaning', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.SignatureMeaning (
        Id        BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_SignatureMeaning PRIMARY KEY,
        Code      NVARCHAR(30)  NOT NULL,
        Name      NVARCHAR(100) NOT NULL,
        Statement NVARCHAR(500) NOT NULL,
        CONSTRAINT UQ_SignatureMeaning_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.SignatureMeaning ON;
    INSERT INTO Quality.SignatureMeaning (Id, Code, Name, Statement) VALUES
        (1, N'ControlledRunRelease', N'Super-lot release',
            N'I confirm the Controlled Run Tag was acted on and the 200% inspection was completed for the members being released.'),
        (2, N'DeviationApproval', N'Deviation approval',
            N'I approve this deviation: the condition described does not affect part performance and the affected material is accepted for use as is.');
    SET IDENTITY_INSERT Quality.SignatureMeaning OFF;

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'What a signature means, and the exact statement shown to the signer. The statement is COPIED onto Quality.Signature at signing, so rewording a row here never changes what somebody already signed.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'SignatureMeaning';
END
GO

-- ---- 3. Quality.Signature (append-only) ----
IF OBJECT_ID(N'Quality.Signature', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.Signature (
        Id                 BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_Signature PRIMARY KEY,
        SignatureMeaningId BIGINT        NOT NULL CONSTRAINT FK_Signature_Meaning REFERENCES Quality.SignatureMeaning(Id),
        AppUserId          BIGINT        NOT NULL CONSTRAINT FK_Signature_AppUser REFERENCES Location.AppUser(Id),
        SignedAt           DATETIME2(3)  NOT NULL CONSTRAINT DF_Signature_SignedAt DEFAULT (SYSUTCDATETIME()),
        Statement          NVARCHAR(500) NOT NULL,
        LogEntityTypeId    BIGINT        NOT NULL CONSTRAINT FK_Signature_EntityType REFERENCES Audit.LogEntityType(Id),
        EntityId           BIGINT        NOT NULL,
        TerminalLocationId BIGINT        NULL CONSTRAINT FK_Signature_Terminal REFERENCES Location.Location(Id));
    CREATE INDEX IX_Signature_Entity ON Quality.Signature (LogEntityTypeId, EntityId, SignedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'An elevated electronic signature: who approved what, with what meaning, in what words, when. Written only after an AD credential check at the moment of signing. APPEND-ONLY: trigger TR_Signature_Immutable refuses UPDATE and DELETE.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'Signature';
END
GO
CREATE OR ALTER TRIGGER Quality.TR_Signature_Immutable ON Quality.Signature
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    -- THROW, never ROLLBACK: this can fire inside a caller's INSERT-EXEC, where a
    -- ROLLBACK raises Msg 3915. THROW dooms the caller's transaction instead.
    IF EXISTS (SELECT 1 FROM deleted)
        THROW 51010, 'Quality.Signature is append-only: a signature cannot be changed or deleted.', 1;
END;
GO

-- ---- 4. Quality.ControlledRunRelease ----
IF OBJECT_ID(N'Quality.ControlledRunRelease', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunRelease (
        Id                  BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunRelease PRIMARY KEY,
        ControlledRunId     BIGINT        NOT NULL CONSTRAINT FK_ControlledRunRelease_Run REFERENCES Quality.ControlledRun(Id),
        SignatureId         BIGINT        NOT NULL CONSTRAINT FK_ControlledRunRelease_Signature REFERENCES Quality.Signature(Id),
        InspectionConfirmed BIT           NOT NULL,
        MemberCount         INT           NOT NULL,
        Remarks             NVARCHAR(500) NULL,
        ReleasedByUserId    BIGINT        NOT NULL CONSTRAINT FK_ControlledRunRelease_ReleasedBy REFERENCES Location.AppUser(Id),
        ReleasedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunRelease_ReleasedAt DEFAULT (SYSUTCDATETIME()),
        TerminalLocationId  BIGINT        NULL CONSTRAINT FK_ControlledRunRelease_Terminal REFERENCES Location.Location(Id),
        CONSTRAINT CK_ControlledRunRelease_Confirmed CHECK (InspectionConfirmed = 1),
        CONSTRAINT CK_ControlledRunRelease_MemberCount CHECK (MemberCount > 0));
    CREATE INDEX IX_ControlledRunRelease_Run ON Quality.ControlledRunRelease (ControlledRunId, ReleasedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One signed release of some or all members of a super-lot. InspectionConfirmed is the recorded fact that the CRT was acted on and the 200% inspection was completed; it can only be 1. Released members point here through ControlledRunMember.ControlledRunReleaseId.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunRelease';
END
GO

-- ---- 5. Quality.ControlledRunMember: two columns ----
IF COL_LENGTH(N'Quality.ControlledRunMember', N'WasCompleteAtJoin') IS NULL
    ALTER TABLE Quality.ControlledRunMember
        ADD WasCompleteAtJoin BIT NOT NULL CONSTRAINT DF_ControlledRunMember_WasCompleteAtJoin DEFAULT (0);
GO
IF COL_LENGTH(N'Quality.ControlledRunMember', N'ControlledRunReleaseId') IS NULL
    ALTER TABLE Quality.ControlledRunMember
        ADD ControlledRunReleaseId BIGINT NULL
            CONSTRAINT FK_ControlledRunMember_Release REFERENCES Quality.ControlledRunRelease(Id);
GO

-- ---- 6. Quality.ControlledRunResult ----
IF OBJECT_ID(N'Quality.ControlledRunResult', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunResult (
        Id                    BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunResult PRIMARY KEY,
        ControlledRunMemberId BIGINT        NOT NULL CONSTRAINT FK_ControlledRunResult_Member REFERENCES Quality.ControlledRunMember(Id),
        DispositionCodeId     BIGINT        NOT NULL CONSTRAINT FK_ControlledRunResult_Disposition REFERENCES Quality.DispositionCode(Id),
        Quantity              INT           NOT NULL,
        DefectCodeId          BIGINT        NULL CONSTRAINT FK_ControlledRunResult_DefectCode REFERENCES Quality.DefectCode(Id),
        -- The Workorder.RejectEvent this entry produced. NULL = nothing was taken off
        -- a LOT (a count-only outcome, or scrap recorded against a container).
        -- No FK: Workorder.RejectEvent is a high-volume event table; this is a pointer.
        RejectEventId         BIGINT        NULL,
        Remarks               NVARCHAR(500) NULL,
        RecordedByUserId      BIGINT        NOT NULL CONSTRAINT FK_ControlledRunResult_RecordedBy REFERENCES Location.AppUser(Id),
        TerminalLocationId    BIGINT        NULL CONSTRAINT FK_ControlledRunResult_Terminal REFERENCES Location.Location(Id),
        RecordedAt            DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunResult_RecordedAt DEFAULT (SYSUTCDATETIME()),
        VoidedAt              DATETIME2(3)  NULL,
        VoidedByUserId        BIGINT        NULL CONSTRAINT FK_ControlledRunResult_VoidedBy REFERENCES Location.AppUser(Id),
        VoidRemarks           NVARCHAR(500) NULL,
        CONSTRAINT CK_ControlledRunResult_Quantity CHECK (Quantity > 0),
        CONSTRAINT CK_ControlledRunResult_VoidPaired CHECK (
            (VoidedAt IS NULL AND VoidedByUserId IS NULL AND VoidRemarks IS NULL) OR
            (VoidedAt IS NOT NULL AND VoidedByUserId IS NOT NULL AND VoidRemarks IS NOT NULL)));
    CREATE INDEX IX_ControlledRunResult_Member ON Quality.ControlledRunResult (ControlledRunMemberId)
        INCLUDE (DispositionCodeId, Quantity, RejectEventId, VoidedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One inspection result entry against a super-lot member: a disposition and a quantity. Never edited; a wrong entry is voided (VoidedAt) and entered again. RejectEventId is set when a Scrap entry took pieces off a LOT.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunResult';
END
GO

-- ---- 7. Quality.ControlledRunDeviation ----
IF OBJECT_ID(N'Quality.ControlledRunDeviation', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunDeviation (
        Id                 BIGINT         NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunDeviation PRIMARY KEY,
        ControlledRunId    BIGINT         NOT NULL CONSTRAINT FK_ControlledRunDeviation_Run REFERENCES Quality.ControlledRun(Id),
        DeviationNumber    NVARCHAR(15)   NOT NULL,
        ExternalReference  NVARCHAR(50)   NULL,
        Description        NVARCHAR(1000) NOT NULL,
        Justification      NVARCHAR(1000) NOT NULL,
        DefectCodeId       BIGINT         NULL CONSTRAINT FK_ControlledRunDeviation_DefectCode REFERENCES Quality.DefectCode(Id),
        AffectedQuantity   INT            NULL,
        SignatureId        BIGINT         NOT NULL CONSTRAINT FK_ControlledRunDeviation_Signature REFERENCES Quality.Signature(Id),
        RaisedByUserId     BIGINT         NOT NULL CONSTRAINT FK_ControlledRunDeviation_RaisedBy REFERENCES Location.AppUser(Id),
        RaisedAt           DATETIME2(3)   NOT NULL CONSTRAINT DF_ControlledRunDeviation_RaisedAt DEFAULT (SYSUTCDATETIME()),
        TerminalLocationId BIGINT         NULL CONSTRAINT FK_ControlledRunDeviation_Terminal REFERENCES Location.Location(Id),
        CONSTRAINT UQ_ControlledRunDeviation_Number UNIQUE (DeviationNumber),
        CONSTRAINT CK_ControlledRunDeviation_Text CHECK (LEN(LTRIM(RTRIM(Description))) > 0 AND LEN(LTRIM(RTRIM(Justification))) > 0),
        CONSTRAINT CK_ControlledRunDeviation_Quantity CHECK (AffectedQuantity IS NULL OR AffectedQuantity > 0));
    CREATE INDEX IX_ControlledRunDeviation_Run ON Quality.ControlledRunDeviation (ControlledRunId, RaisedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'A signed deviation (what MPP call the nonconformance) on a super-lot: a condition found by the inspection and judged not to affect part performance. Required before a member with a Use-As-Is result can be released.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunDeviation';
END
GO

-- ---- 8. Location.SessionPolicy: the Quality window ----
IF COL_LENGTH(N'Location.SessionPolicy', N'QualityElevationTimeoutSeconds') IS NULL
    ALTER TABLE Location.SessionPolicy
        ADD QualityElevationTimeoutSeconds INT NOT NULL CONSTRAINT DF_SessionPolicy_QualityElevTimeout DEFAULT 1800;
GO
IF COL_LENGTH(N'Location.SessionPolicy', N'QualityElevationMaxSeconds') IS NULL
    ALTER TABLE Location.SessionPolicy
        ADD QualityElevationMaxSeconds INT NOT NULL CONSTRAINT DF_SessionPolicy_QualityElevMax DEFAULT 14400;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_SessionPolicy_QualityElevation')
    ALTER TABLE Location.SessionPolicy WITH CHECK
        ADD CONSTRAINT CK_SessionPolicy_QualityElevation
            CHECK (QualityElevationTimeoutSeconds BETWEEN 30 AND 3600
                   AND QualityElevationMaxSeconds BETWEEN 30 AND 28800
                   AND QualityElevationMaxSeconds >= QualityElevationTimeoutSeconds);
GO

-- ---- 9. Audit event codes (plain PKs: next free id, guarded by Code) ----
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Description NVARCHAR(500), Ord INT IDENTITY(1,1));
INSERT INTO @Ev (Code, Name, Description) VALUES
    (N'ControlledRunResultRecorded',  N'Super-lot Results Recorded', N'Inspection results were recorded against super-lot members.'),
    (N'ControlledRunResultVoided',    N'Super-lot Result Voided',    N'An inspection result entry was voided.'),
    (N'ControlledRunReleased',        N'Super-lot Members Released', N'Members of a super-lot were released under a signature.'),
    (N'ControlledRunDeviationRaised', N'Super-lot Deviation Raised', N'A signed deviation was raised on a super-lot.');
DECLARE @Base BIGINT = (SELECT ISNULL(MAX(Id), 0) FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @Base + ROW_NUMBER() OVER (ORDER BY e.Ord), e.Code, e.Name, e.Description
FROM @Ev e
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType x WHERE x.Code = e.Code);
GO

IF OBJECT_ID(N'Quality.ControlledRunResult', N'U') IS NULL OR OBJECT_ID(N'Quality.Signature', N'U') IS NULL
    THROW 51000, 'Migration 0110: Quality.ControlledRunResult / Quality.Signature did not land.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0110_controlled_run_results_signoff')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0110_controlled_run_results_signoff',
            N'Super-lot pieces 2+3: Quality.Signature (+meaning, append-only trigger), ControlledRunRelease, ControlledRunResult, ControlledRunDeviation; ControlledRunMember.WasCompleteAtJoin / ControlledRunReleaseId; SessionPolicy Quality window; Accepted disposition, Released end reason, DV sequence, audit codes. Do NOT deploy alone.');
GO
PRINT 'Migration 0110 (controlled_run_results_signoff) applied.';
GO
