-- ============================================================
-- Migration:   0097_diecast_shift_reconciliation.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-22
-- Description: Die cast shift reconciliation. Spec:
--              docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md
--              (sec 4, amendments sec 14).
--
--              1. Workorder.DieCastReconciliationReason -- why a team lead is
--                 reconciling a past shift (shaped like DieCastVarianceReason).
--              2. Workorder.DieCastShiftReconciliation -- one header row per
--                 save. It is the late-entry marker, the audit anchor, and what
--                 clears the dashboard's "not reconciled" signal.
--              3. Workorder.DieCastReconciliationMove -- the durable record of
--                 every row moved to another shift (the ShiftId is re-stamped
--                 in place, as Oee.ShiftOverride_Restamp does).
--              4. ReconciliationId on DieCastContribution, RejectEvent and
--                 DieCastCounterAnchor; RejectEvent.ApprovedByUserId (the press
--                 sheet's QAS column).
--              5. CK_DieCastContribution_DeltaNonNeg relaxed: a negative credit
--                 is legal only on a reconciliation row (compensating rows,
--                 spec D13). Live paths still cannot write one.
--              6. Anchor reason ShiftReconciliation (amendment A3).
--              7. Audit vocabulary.
--
--              RejectEvent is partitioned: the new columns are nullable with
--              no default (metadata-only), and its new filtered index is
--              created ON ps_MonthlyUtc(RecordedAt) so sliding-window TRUNCATE
--              retention (B2) keeps working.
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0097_diecast_shift_reconciliation')
BEGIN PRINT 'Migration 0097 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. reasons ----
IF OBJECT_ID(N'Workorder.DieCastReconciliationReason', N'U') IS NULL
    CREATE TABLE Workorder.DieCastReconciliationReason (
        Id           BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_DieCastReconciliationReason PRIMARY KEY,
        Code         NVARCHAR(50)  NOT NULL,
        Name         NVARCHAR(100) NOT NULL,
        RequiresNote BIT           NOT NULL CONSTRAINT DF_DCRR_RequiresNote DEFAULT 0,
        SortOrder    INT           NOT NULL CONSTRAINT DF_DCRR_SortOrder DEFAULT 0,
        CONSTRAINT UQ_DieCastReconciliationReason_Code UNIQUE (Code)
    );
GO
MERGE Workorder.DieCastReconciliationReason AS t
USING (VALUES
    (N'MissedEntry',  N'Shift not entered',                     0, 1),
    (N'WrongShift',   N'Entered against the wrong shift',       0, 2),
    (N'WrongNumbers', N'Recorded numbers did not match actual', 0, 3),
    (N'Other',        N'Other',                                 1, 4)
) AS s (Code, Name, RequiresNote, SortOrder)
ON t.Code = s.Code
WHEN MATCHED THEN UPDATE SET t.Name = s.Name, t.RequiresNote = s.RequiresNote, t.SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (Code, Name, RequiresNote, SortOrder) VALUES (s.Code, s.Name, s.RequiresNote, s.SortOrder);
GO

-- ---- 2. header ----
IF OBJECT_ID(N'Workorder.DieCastShiftReconciliation', N'U') IS NULL
    CREATE TABLE Workorder.DieCastShiftReconciliation (
        Id                 BIGINT         NOT NULL IDENTITY(1,1) CONSTRAINT PK_DieCastShiftReconciliation PRIMARY KEY,
        ShiftId            BIGINT         NOT NULL CONSTRAINT FK_DCSR_Shift    REFERENCES Oee.Shift(Id),
        CellLocationId     BIGINT         NOT NULL CONSTRAINT FK_DCSR_Cell     REFERENCES Location.Location(Id),
        ToolId             BIGINT         NOT NULL CONSTRAINT FK_DCSR_Tool     REFERENCES Tools.Tool(Id),
        ReasonId           BIGINT         NOT NULL CONSTRAINT FK_DCSR_Reason   REFERENCES Workorder.DieCastReconciliationReason(Id),
        Note               NVARCHAR(500)  NULL,
        ActualTotalShots   INT            NULL,
        ActualGoodShots    INT            NULL,
        ActualWarmUpShots  INT            NULL,
        DieShotCountBefore INT            NOT NULL,
        DieShotCountAfter  INT            NOT NULL,
        AppUserId          BIGINT         NOT NULL CONSTRAINT FK_DCSR_AppUser  REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT         NULL     CONSTRAINT FK_DCSR_Terminal REFERENCES Location.Location(Id),
        CreatedAt          DATETIME2(3)   NOT NULL CONSTRAINT DF_DCSR_CreatedAt DEFAULT SYSUTCDATETIME()
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastShiftReconciliation_ShiftCell')
    CREATE INDEX IX_DieCastShiftReconciliation_ShiftCell
        ON Workorder.DieCastShiftReconciliation (ShiftId, CellLocationId) INCLUDE (ToolId, AppUserId, CreatedAt);
GO

-- ---- 3. moves ----
IF OBJECT_ID(N'Workorder.DieCastReconciliationMove', N'U') IS NULL
    CREATE TABLE Workorder.DieCastReconciliationMove (
        Id               BIGINT NOT NULL IDENTITY(1,1) CONSTRAINT PK_DieCastReconciliationMove PRIMARY KEY,
        ReconciliationId BIGINT NOT NULL CONSTRAINT FK_DCRM_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id),
        LogEntityTypeId  BIGINT NOT NULL CONSTRAINT FK_DCRM_EntityType     REFERENCES Audit.LogEntityType(Id),
        EntityId         BIGINT NOT NULL,
        FromShiftId      BIGINT NOT NULL CONSTRAINT FK_DCRM_FromShift      REFERENCES Oee.Shift(Id),
        ToShiftId        BIGINT NOT NULL CONSTRAINT FK_DCRM_ToShift        REFERENCES Oee.Shift(Id)
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastReconciliationMove_Entity')
    CREATE INDEX IX_DieCastReconciliationMove_Entity ON Workorder.DieCastReconciliationMove (LogEntityTypeId, EntityId);
GO

-- ---- 4. columns on existing tables ----
IF COL_LENGTH('Workorder.DieCastContribution', 'ReconciliationId') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD ReconciliationId BIGINT NULL
        CONSTRAINT FK_DieCastContribution_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id);
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ReconciliationId') IS NULL
    ALTER TABLE Workorder.RejectEvent ADD ReconciliationId BIGINT NULL
        CONSTRAINT FK_RejectEvent_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id);
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ApprovedByUserId') IS NULL
    ALTER TABLE Workorder.RejectEvent ADD ApprovedByUserId BIGINT NULL
        CONSTRAINT FK_RejectEvent_ApprovedBy REFERENCES Location.AppUser(Id);
GO
IF COL_LENGTH('Workorder.DieCastCounterAnchor', 'ReconciliationId') IS NULL
    ALTER TABLE Workorder.DieCastCounterAnchor ADD ReconciliationId BIGINT NULL
        CONSTRAINT FK_DieCastCounterAnchor_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastContribution_Reconciliation')
    CREATE INDEX IX_DieCastContribution_Reconciliation
        ON Workorder.DieCastContribution (ReconciliationId) WHERE ReconciliationId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_RejectEvent_Reconciliation')
    CREATE INDEX IX_RejectEvent_Reconciliation
        ON Workorder.RejectEvent (ReconciliationId, RecordedAt) WHERE ReconciliationId IS NOT NULL
        ON ps_MonthlyUtc(RecordedAt);
GO

-- ---- 5. the CHECK (spec D13) ----
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_DieCastContribution_DeltaNonNeg')
    ALTER TABLE Workorder.DieCastContribution DROP CONSTRAINT CK_DieCastContribution_DeltaNonNeg;
GO
ALTER TABLE Workorder.DieCastContribution WITH CHECK ADD CONSTRAINT CK_DieCastContribution_DeltaNonNeg
    CHECK (PieceDelta >= 0 OR ReconciliationId IS NOT NULL);
GO

-- ---- 6. anchor reason (amendment A3) ----
IF NOT EXISTS (SELECT 1 FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'ShiftReconciliation')
    INSERT INTO Workorder.DieCastCounterAnchorReason (Code, Name, Description, SortOrder)
    VALUES (N'ShiftReconciliation', N'Set by a shift reconciliation',
            N'A team lead reconciled the shift against its press sheet and declared its actual total shots. Not offered on the Fix counter dialog.',
            99);
GO

-- ---- 7. audit vocabulary ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'DieCastContribution')
BEGIN
    DECLARE @e1 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@e1, N'DieCastContribution', N'Die Cast Contribution', N'One credit of good pieces to a die cast LOT in a shift.');
END
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'DieCastShiftReconciliation')
BEGIN
    DECLARE @e2 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@e2, N'DieCastShiftReconciliation', N'Die Cast Shift Reconciliation', N'A team lead reconciling one past shift x press x die against its press sheet.');
END
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'DieCastShiftReconciled')
BEGIN
    DECLARE @v1 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@v1, N'DieCastShiftReconciled', N'Die Cast Shift Reconciled', N'A past shift was reconciled: production added, moved or corrected after the fact.');
END
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'DieCastEntryMoved')
BEGIN
    DECLARE @v2 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@v2, N'DieCastEntryMoved', N'Die Cast Entry Moved', N'Recorded die cast rows were re-filed against the shift they belong to.');
END
GO

-- ---- 8. record ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0097_diecast_shift_reconciliation')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0097_diecast_shift_reconciliation',
            N'Die cast shift reconciliation: reason code table, header and move tables; ReconciliationId on DieCastContribution/RejectEvent/DieCastCounterAnchor; RejectEvent.ApprovedByUserId; negative credits allowed on reconciliation rows only; anchor reason ShiftReconciliation; audit vocabulary.');
GO
PRINT 'Migration 0097 (diecast_shift_reconciliation) applied.';
GO
