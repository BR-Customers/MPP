-- ============================================================
-- Migration:   0134_scale_digi_and_pending_press.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-19
-- Description: Assembly Out By Weight scales read through a Digi One SP.
--
--   1. Location.PlcDeviceType += ScaleStationDigi -> ByWeight.
--      An IND570 head running its compiled TaskExpert program, read on its
--      serial port through a Digi One SP (raw TCP 2101). One record per GOOD
--      press: (NET)<w><UOM><u><TWM><0|1><Part><code>. The scale decides the
--      part and whether the tray is good. PlcWatcher routes on the type code
--      to BlueRidge.Workorder.ScaleDigiWatcher; ScaleStationEPrint (0105) is
--      untouched and keeps its own watcher.
--
--   2. Workorder.ScalePendingPressStatus (Pending / Closed / Discarded) and
--      Workorder.ScalePendingPress: a good press whose scale part code matches
--      no MES part is HELD until the operator picks the part on screen; the
--      tray closes on the pick. At most one Pending press per terminal,
--      enforced by a filtered unique index on StatusId = 1 (Pending), which
--      is why Pending must be Id 1.
--
--   3. Audit.LogEventType += ScalePressHeld / ScalePressPicked /
--      ScalePressDiscarded (Workorder.ScalePendingPress_* procs).
--
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md
-- ============================================================

-- ---- 1. device type ----------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType WHERE Code = N'ScaleStationDigi')
BEGIN
    INSERT INTO Location.PlcDeviceType (Code, Name, Description, ClosureMethodCode)
    VALUES (N'ScaleStationDigi', N'Scale Station (Digi)',
            N'IND570 running its TaskExpert program, read on its serial port through a Digi One SP (TCP driver); the scale decides part and good',
            N'ByWeight');
    PRINT 'Migration 0134: PlcDeviceType ScaleStationDigi added.';
END
GO

-- ---- 2. status code table ------------------------------------------------------
IF OBJECT_ID(N'Workorder.ScalePendingPressStatus', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.ScalePendingPressStatus (
        Id   BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ScalePendingPressStatus_Code UNIQUE (Code)
    );
    SET IDENTITY_INSERT Workorder.ScalePendingPressStatus ON;
    INSERT INTO Workorder.ScalePendingPressStatus (Id, Code, Name) VALUES
        (1, N'Pending',   N'Waiting for the operator to pick the part'),
        (2, N'Closed',    N'Part picked; the tray was closed'),
        (3, N'Discarded', N'Discarded by the operator; no tray closed');
    SET IDENTITY_INSERT Workorder.ScalePendingPressStatus OFF;
END
GO

IF NOT EXISTS (SELECT 1 FROM Workorder.ScalePendingPressStatus WHERE Id = 1 AND Code = N'Pending')
    THROW 51000, 'Migration 0134: ScalePendingPressStatus Pending must be Id 1 (the filtered unique index depends on it).', 1;
GO

-- ---- 2b. held presses --------------------------------------------------------------
IF OBJECT_ID(N'Workorder.ScalePendingPress', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.ScalePendingPress (
        Id                  BIGINT         NOT NULL IDENTITY(1,1)
                            CONSTRAINT PK_ScalePendingPress PRIMARY KEY,
        TerminalLocationId  BIGINT         NOT NULL
                            CONSTRAINT FK_ScalePendingPress_Terminal REFERENCES Location.Location(Id),
        ReceivedAt          DATETIME2(3)   NOT NULL,
        NetWeight           DECIMAL(10,3)  NOT NULL,
        Uom                 NVARCHAR(10)   NOT NULL,
        ScalePartCode       NVARCHAR(50)   NOT NULL,
        StatusId            BIGINT         NOT NULL
                            CONSTRAINT FK_ScalePendingPress_Status REFERENCES Workorder.ScalePendingPressStatus(Id),
        ResolvedAt          DATETIME2(3)   NULL,
        ResolvedByAppUserId BIGINT         NULL
                            CONSTRAINT FK_ScalePendingPress_ResolvedBy REFERENCES Location.AppUser(Id),
        ResolvedItemId      BIGINT         NULL
                            CONSTRAINT FK_ScalePendingPress_Item REFERENCES Parts.Item(Id),
        FinishedGoodLotId   BIGINT         NULL
                            CONSTRAINT FK_ScalePendingPress_Lot REFERENCES Lots.Lot(Id)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_ScalePendingPress_Terminal_Pending'
               AND object_id = OBJECT_ID(N'Workorder.ScalePendingPress'))
    CREATE UNIQUE INDEX UX_ScalePendingPress_Terminal_Pending
        ON Workorder.ScalePendingPress (TerminalLocationId)
        WHERE StatusId = 1;
GO

-- ---- 3. audit event types (Id is a plain PK, not identity: the 0113 pattern) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ScalePressHeld')
BEGIN
    DECLARE @E1 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@E1, N'ScalePressHeld', N'Scale Press Held',
            N'A good scale press whose part code matched no MES part was held for the operator to pick the part (Workorder.ScalePendingPress_Hold).');
END
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ScalePressPicked')
BEGIN
    DECLARE @E2 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@E2, N'ScalePressPicked', N'Scale Press Picked',
            N'The operator picked the part for a held scale press and its tray was closed (Workorder.ScalePendingPress_Complete).');
END
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ScalePressDiscarded')
BEGIN
    DECLARE @E3 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@E3, N'ScalePressDiscarded', N'Scale Press Discarded',
            N'The operator discarded a held scale press; no tray was closed (Workorder.ScalePendingPress_Discard).');
END
GO

-- ---- checks -----------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType WHERE Code = N'ScaleStationDigi' AND ClosureMethodCode = N'ByWeight')
    THROW 51000, 'Migration 0134: ScaleStationDigi -> ByWeight did not land.', 1;
IF (SELECT COUNT(*) FROM Audit.LogEventType WHERE Code IN (N'ScalePressHeld', N'ScalePressPicked', N'ScalePressDiscarded')) <> 3
    THROW 51000, 'Migration 0134: LogEventType rows did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0134_scale_digi_and_pending_press')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0134_scale_digi_and_pending_press',
            N'Location.PlcDeviceType += ScaleStationDigi (ByWeight); Workorder.ScalePendingPressStatus + Workorder.ScalePendingPress (held scale presses, one Pending per terminal); LogEventType ScalePressHeld/Picked/Discarded. Apply with Workorder.ScalePendingPress_* v1.0.');
GO
PRINT 'Migration 0134 (scale_digi_and_pending_press) applied.';
GO
