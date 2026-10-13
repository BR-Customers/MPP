-- ============================================================
-- Migration:   0111_container_rework.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-13
-- Description: Super-lot piece 4 of 6 -- container repack. A completed container
--              can be opened for rework, have parts scrapped out of it, be topped
--              up with loose pieces from another container and come back complete
--              with a NEW shipper serial; an emptied container is voided.
--
--   DO NOT DEPLOY TO PRODUCTION ON ITS OWN. Spec:
--   docs/superpowers/specs/2026-10-12-controlled-run-container-repack-design.md
--
--   D5  Two rework statuses. ReworkProcessing = parts are being taken out and
--       scrapped. ReworkFilling = refill-ready. The tray LOTs STAY CLOSED the
--       whole time: the Lots.ContainerRework_* procs change them directly, gated
--       on these statuses, so nothing reappears in a WIP queue or anything else
--       that treats Closed as final.
--   D3  A voided AIM serial is marked on its pool row (VoidedAt). AIM is told
--       nothing yet; Lots.AimShipperIdPool_ListVoided is the worklist for the
--       cancellation post under discussion with MPP.
--   D6  A scrapped serial stays on Lots.ContainerSerial, marked RemovedAt, so the
--       record that it was packed in that container is not lost.
--
--   No piece-move table: a move IS a Workorder.ConsumptionEvent with Consumption
--   genealogy into a newly minted tray LOT.
--
--   Idempotent per statement; ASCII-only (sqlcmd codepage rule).
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0111_container_rework')
BEGIN PRINT 'Migration 0111 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Container statuses ----
IF NOT EXISTS (SELECT 1 FROM Lots.ContainerStatusCode WHERE Code = N'ReworkProcessing')
BEGIN
    SET IDENTITY_INSERT Lots.ContainerStatusCode ON;
    INSERT INTO Lots.ContainerStatusCode (Id, Code, Name) VALUES
        (6, N'ReworkProcessing', N'Rework - processing'),
        (7, N'ReworkFilling',    N'Rework - refill ready');
    SET IDENTITY_INSERT Lots.ContainerStatusCode OFF;
END
GO

-- ---- 2. Lots.ContainerRework ----
IF OBJECT_ID(N'Lots.ContainerRework', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.ContainerRework (
        Id                      BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ContainerRework PRIMARY KEY,
        ContainerId             BIGINT        NOT NULL CONSTRAINT FK_ContainerRework_Container REFERENCES Lots.Container(Id),
        OpenedByUserId          BIGINT        NOT NULL CONSTRAINT FK_ContainerRework_OpenedBy REFERENCES Location.AppUser(Id),
        OpenedAt                DATETIME2(3)  NOT NULL CONSTRAINT DF_ContainerRework_OpenedAt DEFAULT (SYSUTCDATETIME()),
        OpenedAtTerminalId      BIGINT        NULL CONSTRAINT FK_ContainerRework_Terminal REFERENCES Location.Location(Id),
        OriginalCompletedAt     DATETIME2(3)  NULL,
        OriginalAimShipperId    NVARCHAR(50)  NULL,
        OriginalShippingLabelId BIGINT        NULL,
        OriginalPieceCount      INT           NOT NULL,
        ResumedAt               DATETIME2(3)  NULL,
        ResumedByUserId         BIGINT        NULL CONSTRAINT FK_ContainerRework_ResumedBy REFERENCES Location.AppUser(Id),
        ResumedAtLocationId     BIGINT        NULL CONSTRAINT FK_ContainerRework_ResumedAt REFERENCES Location.Location(Id),
        VoidedAt                DATETIME2(3)  NULL,
        VoidedByUserId          BIGINT        NULL CONSTRAINT FK_ContainerRework_VoidedBy REFERENCES Location.AppUser(Id),
        VoidRemarks             NVARCHAR(500) NULL);
    CREATE INDEX IX_ContainerRework_Container ON Lots.ContainerRework (ContainerId, OpenedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One row each time a completed container is opened for rework (super-lot repack). Records what the container was (when it completed, its serial and label, how many pieces) before parts were taken out. The current rework of a container is its latest row.',
        @level0type = N'SCHEMA', @level0name = N'Lots', @level1type = N'TABLE', @level1name = N'ContainerRework';
END
GO

-- ---- 3. AIM pool: a voided serial ----
IF COL_LENGTH(N'Lots.AimShipperIdPool', N'VoidedAt') IS NULL
    ALTER TABLE Lots.AimShipperIdPool ADD
        VoidedAt       DATETIME2(3)  NULL,
        VoidedByUserId BIGINT        NULL CONSTRAINT FK_AimPool_VoidedBy REFERENCES Location.AppUser(Id),
        VoidReason     NVARCHAR(200) NULL;
GO

-- ---- 4. Container serial: a scrapped part ----
IF COL_LENGTH(N'Lots.ContainerSerial', N'RemovedAt') IS NULL
    ALTER TABLE Lots.ContainerSerial ADD
        RemovedAt            DATETIME2(3) NULL,
        RemovedRejectEventId BIGINT       NULL;
GO

-- ---- 5. Super-lot membership end reason ----
IF NOT EXISTS (SELECT 1 FROM Quality.ControlledRunMemberEndReason WHERE Code = N'ContainerVoided')
BEGIN
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason ON;
    INSERT INTO Quality.ControlledRunMemberEndReason (Id, Code, Name) VALUES (5, N'ContainerVoided', N'Container emptied and voided');
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason OFF;
END
GO

-- ---- 6. Audit codes (plain PKs: next free id, guarded by Code) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'ContainerRework')
BEGIN
    DECLARE @EntId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@EntId, N'ContainerRework', N'Container rework', N'Lots.ContainerRework - a container opened for repack (routes to OperationLog).');
END
GO
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Description NVARCHAR(500), Ord INT IDENTITY(1,1));
INSERT INTO @Ev (Code, Name, Description) VALUES
    (N'ContainerReworkOpened',       N'Container Opened For Rework', N'A completed container was opened for rework; its serial and label were voided.'),
    (N'ContainerReworkScrapped',     N'Container Rework Scrap',      N'Parts were scrapped out of a container under rework.'),
    (N'ContainerPiecesMoved',        N'Container Pieces Moved',      N'Pieces were moved from one container under rework into another.'),
    (N'ContainerReworkStageChanged', N'Container Rework Stage',      N'A container under rework changed stage or was sent to a location.'),
    (N'ContainerReworkResumed',      N'Container Rework Resumed',    N'A refill-ready container was made the open container at a cell.'),
    (N'ContainerVoided',             N'Container Voided',            N'An emptied container was voided.');
DECLARE @Base BIGINT = (SELECT ISNULL(MAX(Id), 0) FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @Base + ROW_NUMBER() OVER (ORDER BY e.Ord), e.Code, e.Name, e.Description
FROM @Ev e
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType x WHERE x.Code = e.Code);
GO

IF OBJECT_ID(N'Lots.ContainerRework', N'U') IS NULL
    THROW 51000, 'Migration 0111: Lots.ContainerRework did not land.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0111_container_rework')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0111_container_rework',
            N'Super-lot piece 4: container statuses ReworkProcessing / ReworkFilling; Lots.ContainerRework; AimShipperIdPool void columns; ContainerSerial.RemovedAt; end reason ContainerVoided; audit codes. Do NOT deploy alone.');
GO
PRINT 'Migration 0111 (container_rework) applied.';
GO
