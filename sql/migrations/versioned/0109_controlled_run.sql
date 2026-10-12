-- ============================================================
-- Migration:   0109_controlled_run.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-12
-- Description: Super-lot (Controlled Run) -- a stored quality case that groups
--              LOTs and containers placed on a Controlled Run Tag for one reason.
--
--   PIECE 1 OF 6. DO NOT DEPLOY TO PRODUCTION ON ITS OWN. A completed container
--   is an eligible member here, but only a later piece can block it at the dock
--   (spec 9.2). Spec:
--   docs/superpowers/specs/2026-10-12-controlled-run-super-lot-design.md
--
--   D1  The run is a STORED MEMBER LIST, not a rule. How members were chosen
--       (part / line / time / genealogy / by hand) is recorded on the header.
--   D3  A member is a LOT or a container, never both. WIP is listed as LOTs;
--       packed finished goods as the container (its tray LOTs are implied).
--   D4  A unit is in at most one OPEN run -- the two filtered unique indexes.
--   D5  Membership never blocks by itself: joining sets Lots.Lot.CrtActive, so
--       every existing CRT block applies unchanged.
--   D7  IX_ControlledRun_AutoJoin is read by Lots.ufn_CrtForMint on EVERY mint.
--   D11 The label belongs to the run: four copies per request, on demand.
--
--   Why a member carries its own EndedAt: a filtered index cannot look at the
--   parent row's status. Closing a run stamps every open member, which is also
--   what frees those units to join a later run.
--
--   Idempotent per statement; ASCII-only (sqlcmd codepage rule).
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0109_controlled_run')
BEGIN PRINT 'Migration 0109 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Code tables (read-only) ----
IF OBJECT_ID(N'Quality.ControlledRunStatusCode', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunStatusCode (
        Id   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunStatusCode PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ControlledRunStatusCode_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.ControlledRunStatusCode ON;
    INSERT INTO Quality.ControlledRunStatusCode (Id, Code, Name) VALUES
        (1, N'Open', N'Open'), (2, N'Closed', N'Closed'), (3, N'Cancelled', N'Cancelled');
    SET IDENTITY_INSERT Quality.ControlledRunStatusCode OFF;
END
GO
IF OBJECT_ID(N'Quality.ControlledRunJoinMethod', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunJoinMethod (
        Id   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunJoinMethod PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ControlledRunJoinMethod_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.ControlledRunJoinMethod ON;
    INSERT INTO Quality.ControlledRunJoinMethod (Id, Code, Name) VALUES
        (1, N'Selected', N'Selected'), (2, N'Manual', N'Scanned in'),
        (3, N'AutoJoined', N'New production'), (4, N'Descendant', N'Made from a member');
    SET IDENTITY_INSERT Quality.ControlledRunJoinMethod OFF;
END
GO
IF OBJECT_ID(N'Quality.ControlledRunMemberEndReason', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunMemberEndReason (
        Id   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunMemberEndReason PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ControlledRunMemberEndReason_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason ON;
    INSERT INTO Quality.ControlledRunMemberEndReason (Id, Code, Name) VALUES
        (1, N'Removed', N'Removed'), (2, N'RunClosed', N'Super-lot closed'), (3, N'RunCancelled', N'Super-lot cancelled');
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason OFF;
END
GO

-- ---- 2. Quality.ControlledRun ----
IF OBJECT_ID(N'Quality.ControlledRun', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRun (
        Id                    BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRun PRIMARY KEY,
        RunNumber             NVARCHAR(15)  NOT NULL,
        ControlledRunStatusId BIGINT        NOT NULL CONSTRAINT FK_ControlledRun_Status REFERENCES Quality.ControlledRunStatusCode(Id),
        Reason                NVARCHAR(500) NOT NULL,
        AnchorLotId           BIGINT        NULL CONSTRAINT FK_ControlledRun_AnchorLot REFERENCES Lots.Lot(Id),
        SelectionItemId       BIGINT        NULL CONSTRAINT FK_ControlledRun_Item REFERENCES Parts.Item(Id),
        SelectionLocationId   BIGINT        NULL CONSTRAINT FK_ControlledRun_Location REFERENCES Location.Location(Id),
        SelectionFromAt       DATETIME2(3)  NULL,
        SelectionToAt         DATETIME2(3)  NULL,
        IncludeDescendants    BIT           NOT NULL CONSTRAINT DF_ControlledRun_IncludeDescendants DEFAULT (0),
        AutoJoinEnabled       BIT           NOT NULL CONSTRAINT DF_ControlledRun_AutoJoinEnabled DEFAULT (0),
        AutoJoinEndedAt       DATETIME2(3)  NULL,
        AutoJoinEndedByUserId BIGINT        NULL CONSTRAINT FK_ControlledRun_AutoJoinEndedBy REFERENCES Location.AppUser(Id),
        OpenedByUserId        BIGINT        NOT NULL CONSTRAINT FK_ControlledRun_OpenedBy REFERENCES Location.AppUser(Id),
        OpenedAt              DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRun_OpenedAt DEFAULT (SYSUTCDATETIME()),
        OpenedAtTerminalId    BIGINT        NULL CONSTRAINT FK_ControlledRun_Terminal REFERENCES Location.Location(Id),
        ClosedByUserId        BIGINT        NULL CONSTRAINT FK_ControlledRun_ClosedBy REFERENCES Location.AppUser(Id),
        ClosedAt              DATETIME2(3)  NULL,
        CloseRemarks          NVARCHAR(500) NULL,
        RowVersion            ROWVERSION    NOT NULL,
        CONSTRAINT UQ_ControlledRun_RunNumber UNIQUE (RunNumber),
        CONSTRAINT CK_ControlledRun_Reason CHECK (LEN(LTRIM(RTRIM(Reason))) > 0),
        CONSTRAINT CK_ControlledRun_ClosePaired CHECK (
            (ClosedByUserId IS NULL AND ClosedAt IS NULL) OR (ClosedByUserId IS NOT NULL AND ClosedAt IS NOT NULL)),
        CONSTRAINT CK_ControlledRun_AutoJoinNeedsItem CHECK (AutoJoinEnabled = 0 OR SelectionItemId IS NOT NULL));

    CREATE INDEX IX_ControlledRun_Open ON Quality.ControlledRun (ControlledRunStatusId, OpenedAt)
        WHERE ControlledRunStatusId = 1;
    -- Read by Lots.ufn_CrtForMint on EVERY mint in the plant. Keep it a seek on a tiny set.
    CREATE INDEX IX_ControlledRun_AutoJoin ON Quality.ControlledRun (SelectionItemId)
        INCLUDE (SelectionLocationId) WHERE ControlledRunStatusId = 1 AND AutoJoinEnabled = 1;

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'A super-lot: one quality case grouping LOTs and containers placed on a Controlled Run Tag for the same reason. Members are in Quality.ControlledRunMember. Membership never blocks by itself - joining sets Lots.Lot.CrtActive.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRun';
END
GO

-- ---- 3. Quality.ControlledRunMember ----
IF OBJECT_ID(N'Quality.ControlledRunMember', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunMember (
        Id                             BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunMember PRIMARY KEY,
        ControlledRunId                BIGINT        NOT NULL CONSTRAINT FK_ControlledRunMember_Run REFERENCES Quality.ControlledRun(Id),
        LotId                          BIGINT        NULL CONSTRAINT FK_ControlledRunMember_Lot REFERENCES Lots.Lot(Id),
        ContainerId                    BIGINT        NULL CONSTRAINT FK_ControlledRunMember_Container REFERENCES Lots.Container(Id),
        ControlledRunJoinMethodId      BIGINT        NOT NULL CONSTRAINT FK_ControlledRunMember_JoinMethod REFERENCES Quality.ControlledRunJoinMethod(Id),
        CrtSetByRun                    BIT           NOT NULL,
        AddedByUserId                  BIGINT        NOT NULL CONSTRAINT FK_ControlledRunMember_AddedBy REFERENCES Location.AppUser(Id),
        AddedAt                        DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunMember_AddedAt DEFAULT (SYSUTCDATETIME()),
        EndedAt                        DATETIME2(3)  NULL,
        EndedByUserId                  BIGINT        NULL CONSTRAINT FK_ControlledRunMember_EndedBy REFERENCES Location.AppUser(Id),
        ControlledRunMemberEndReasonId BIGINT        NULL CONSTRAINT FK_ControlledRunMember_EndReason REFERENCES Quality.ControlledRunMemberEndReason(Id),
        EndRemarks                     NVARCHAR(500) NULL,
        CONSTRAINT CK_ControlledRunMember_LotXorContainer CHECK (
            (LotId IS NOT NULL AND ContainerId IS NULL) OR (LotId IS NULL AND ContainerId IS NOT NULL)),
        CONSTRAINT CK_ControlledRunMember_EndPaired CHECK (
            (EndedAt IS NULL AND EndedByUserId IS NULL AND ControlledRunMemberEndReasonId IS NULL) OR
            (EndedAt IS NOT NULL AND EndedByUserId IS NOT NULL AND ControlledRunMemberEndReasonId IS NOT NULL)));

    -- D4: one OPEN membership per unit across ALL runs.
    CREATE UNIQUE INDEX UX_ControlledRunMember_OpenLot ON Quality.ControlledRunMember (LotId)
        WHERE EndedAt IS NULL AND LotId IS NOT NULL;
    CREATE UNIQUE INDEX UX_ControlledRunMember_OpenContainer ON Quality.ControlledRunMember (ContainerId)
        WHERE EndedAt IS NULL AND ContainerId IS NOT NULL;
    CREATE INDEX IX_ControlledRunMember_Run ON Quality.ControlledRunMember (ControlledRunId, EndedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One LOT or one container in a super-lot (never both). WIP is listed as LOTs; packed finished goods as the container. EndedAt NULL = currently a member; a unit has at most one open membership.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunMember';
END
GO

-- ---- 4. Quality.ControlledRunLabel (append-only print log) ----
IF OBJECT_ID(N'Quality.ControlledRunLabel', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunLabel (
        Id                 BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunLabel PRIMARY KEY,
        ControlledRunId    BIGINT        NOT NULL CONSTRAINT FK_ControlledRunLabel_Run REFERENCES Quality.ControlledRun(Id),
        Copies             INT           NOT NULL,
        ZplContent         NVARCHAR(MAX) NOT NULL,
        PrinterName        NVARCHAR(100) NULL,
        PrintedByUserId    BIGINT        NOT NULL CONSTRAINT FK_ControlledRunLabel_PrintedBy REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT        NULL CONSTRAINT FK_ControlledRunLabel_Terminal REFERENCES Location.Location(Id),
        PrintedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunLabel_PrintedAt DEFAULT (SYSUTCDATETIME()));
    CREATE INDEX IX_ControlledRunLabel_Run ON Quality.ControlledRunLabel (ControlledRunId, PrintedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Append-only log of super-lot label print requests (one row per request, Copies labels each).',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunLabel';
END
GO

-- ---- 5. Run-number sequence ----
IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun')
    INSERT INTO Lots.IdentifierSequence (Code, Name, Description, FormatString, StartingValue, EndingValue, LastValue)
    VALUES (N'ControlledRun', N'Super-lot number', N'Quality.ControlledRun.RunNumber counter.', N'CR{0:D6}', 1, 999999, 0);
GO

-- ---- 6. Label type + template ----
IF NOT EXISTS (SELECT 1 FROM Lots.LabelTypeCode WHERE Code = N'ControlledRun')
    INSERT INTO Lots.LabelTypeCode (Code, Name) VALUES (N'ControlledRun', N'Super-lot Label');
GO
DECLARE @TypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'ControlledRun');
DECLARE @Zpl NVARCHAR(MAX) =
      N'^XA^LH0,0^PW812'
    + N'^FO0,0^GB812,110,110^FS'
    + N'^FO0,20^A0N,84,84^FB812,1,0,C^FR^FDSUPER-LOT^FS'
    + N'^FO0,128^A0N,132,112^FB812,1,0,C^FD{RunNumber}^FS'
    + N'^FO200,272^BY3,3,110^BCN,110,N,N,N^FD{RunNumber}^FS'
    + N'^FO40,406^A0N,36,36^FD{PartNumber}^FS'
    + N'^FO40,450^A0N,26,26^FB730,2,0,L^FD{Reason}^FS'
    + N'^FO40,512^A0N,24,24^FDOpened {OpenedAt} by {OpenedBy}^FS'
    + N'^FO0,548^GB812,61,61^FS'
    + N'^FO0,562^A0N,34,34^FB812,1,0,C^FR^FDQUALITY - DO NOT USE - SCAN FOR STATUS^FS'
    + N'^PQ{Copies}^XZ';
IF @TypeId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM Lots.LabelTemplate WHERE LabelTypeCodeId = @TypeId AND DeprecatedAt IS NULL)
    INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody) VALUES (@TypeId, @Zpl);
GO

-- ---- 7. Audit codes (plain PKs, not identity: next free id, guarded by Code) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'ControlledRun')
BEGIN
    DECLARE @EntId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@EntId, N'ControlledRun', N'Super-lot', N'Quality.ControlledRun - a super-lot (routes to OperationLog).');
END
GO
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Description NVARCHAR(500), Ord INT IDENTITY(1,1));
INSERT INTO @Ev (Code, Name, Description) VALUES
    (N'ControlledRunOpened',        N'Super-lot Opened',         N'A super-lot was opened.'),
    (N'ControlledRunMemberAdded',   N'Super-lot Member Added',   N'LOTs or containers were added to a super-lot.'),
    (N'ControlledRunMemberRemoved', N'Super-lot Member Removed', N'A LOT or container was removed from a super-lot.'),
    (N'ControlledRunWindowChanged', N'Super-lot Window Changed', N'Automatic adding of new production was ended or resumed.'),
    (N'ControlledRunClosed',        N'Super-lot Closed',         N'A super-lot was closed.'),
    (N'ControlledRunCancelled',     N'Super-lot Cancelled',      N'A super-lot was cancelled.'),
    (N'ControlledRunLabelPrinted',  N'Super-lot Label Printed',  N'Super-lot labels were printed.');
DECLARE @Base BIGINT = (SELECT ISNULL(MAX(Id), 0) FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @Base + ROW_NUMBER() OVER (ORDER BY e.Ord), e.Code, e.Name, e.Description
FROM @Ev e
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType x WHERE x.Code = e.Code);
GO

IF OBJECT_ID(N'Quality.ControlledRunMember', N'U') IS NULL
    THROW 51000, 'Migration 0109: Quality.ControlledRunMember did not land.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0109_controlled_run')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0109_controlled_run',
            N'Super-lot (Controlled Run): Quality.ControlledRun / ControlledRunMember / ControlledRunLabel + 3 code tables; ControlledRun sequence, label type + template, audit codes. Piece 1 of 6 - do NOT deploy alone.');
GO
PRINT 'Migration 0109 (controlled_run) applied.';
GO
