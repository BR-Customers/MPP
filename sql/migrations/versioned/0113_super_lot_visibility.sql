-- ============================================================
-- Migration:   0113_super_lot_visibility.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-21
-- Description: Super-lot piece 6 of 6 -- visibility.
--
--   DO NOT DEPLOY TO PRODUCTION ON ITS OWN. Spec:
--   docs/superpowers/specs/2026-10-12-controlled-run-visibility-design.md (3.2)
--
--   Audit.LogEventType.RepeatsLotTimeline BIT NOT NULL DEFAULT 0
--       1 = this event type repeats a fact Lots.Lot_GetAttributeHistory already
--       draws from a record table, so the History tab skips it. A new type
--       defaults to 0 and SHOWS (exclude list, not include list).
--   Audit.LogEventType.LotTimelineKind NVARCHAR(20) NULL
--       The label the History tab shows for the audit row. NULL reads as 'Event'.
--   Six per-LOT super-lot event codes (entity 'Lot' -> Lots.LotEventLog).
--
--   Record-table streams of Lot_GetAttributeHistory: LotAttributeChange,
--   LotStatusHistory, LotMovement, PauseEvent, LotGenealogy, LotLabel,
--   Workorder.ProductionEvent, RejectEvent, DieCastContribution.
--
--   INVENTORY of codes written with entity 'Lot' (routes to LotEventLog), from
--   sql/migrations/repeatable. Flag / kind / why:
--     LotCreated               1  -        Lot_Create et al. write LotStatusHistory + LotMovement
--     LotMoved                 1  -        LotMovement row
--     LotStatusChanged         1  -        LotStatusHistory row (every writer inserts one)
--     LotUpdated               1  -        LotAttributeChange row (Update / UpdateAttribute / correction)
--     LotSplit                 1  -        LotGenealogy edge + LotStatusHistory
--     LotMerged                1  -        LotGenealogy edge + LotStatusHistory
--     LotConsumed              1  -        LotGenealogy (Consumption) edge
--     DieCastPieceContributed  1  -        Workorder.DieCastContribution row
--     DieCastLotOpened         1  -        LotStatusHistory + LotMovement + LotGenealogy at mint
--     DieCastLotReleased       1  -        LotStatusHistory + LotMovement
--     DieCastLotVoided         1  -        LotStatusHistory
--     MachiningInPicked        1  -        LotMovement + ProductionEvent
--     MachiningOutCompleted    1  -        ProductionEvent + LotGenealogy
--     CrtActivated             0  CRT      no record table (CRT is audit-only)
--     CrtCleared               0  CRT      no record table
--     MissedCrtInspect         0  CRT      no record table
--     VendorReturnMarked       0  Vendor return   Lots.VendorReturn is not a timeline stream
--     VendorReturnConfirmed    0  Vendor return
--     VendorReturnCancelled    0  Vendor return
--     LotReworkStarted         0  Rework   the override move is a LotMovement, the rework is not
--     LotReworkCompleted       0  Rework   the Trim OUT ProductionEvent does not say rework closed
--     MaterialSubstituteOverride 0 -       ConsumptionEvent is not a timeline stream
--     ControlledRunLot* (six)  0  Super-lot new in this migration
--   Not in the table: container-rework codes (ContainerRework* / ContainerPiecesMoved /
--   ContainerVoided) log against entity ContainerRework -> Audit.OperationLog, never
--   LotEventLog; LabelPrinted logs against entity LotLabel -> OperationLog.
--
--   Idempotent per statement; ASCII-only (sqlcmd codepage rule).
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0113_super_lot_visibility')
BEGIN PRINT 'Migration 0113 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Columns ----
IF COL_LENGTH(N'Audit.LogEventType', N'RepeatsLotTimeline') IS NULL
    ALTER TABLE Audit.LogEventType ADD RepeatsLotTimeline BIT NOT NULL
        CONSTRAINT DF_LogEventType_RepeatsLotTimeline DEFAULT (0);
GO
IF COL_LENGTH(N'Audit.LogEventType', N'LotTimelineKind') IS NULL
    ALTER TABLE Audit.LogEventType ADD LotTimelineKind NVARCHAR(20) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(N'Audit.LogEventType')
               AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'Audit.LogEventType'), N'RepeatsLotTimeline', 'ColumnId') AND name = N'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'1 = this event type repeats a fact the LOT History timeline already draws from a record table (created, moved, status, attribute, genealogy, production, die-cast contribution), so the History tab skips it. Defaults to 0: a new event type shows until someone flags it.',
        @level0type = N'SCHEMA', @level0name = N'Audit', @level1type = N'TABLE', @level1name = N'LogEventType',
        @level2type = N'COLUMN', @level2name = N'RepeatsLotTimeline';
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(N'Audit.LogEventType')
               AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'Audit.LogEventType'), N'LotTimelineKind', 'ColumnId') AND name = N'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Label the LOT History tab shows for this audit event (CRT, Vendor return, Rework, Super-lot). NULL reads as Event.',
        @level0type = N'SCHEMA', @level0name = N'Audit', @level1type = N'TABLE', @level1name = N'LogEventType',
        @level2type = N'COLUMN', @level2name = N'LotTimelineKind';
GO

-- ---- 2. Per-LOT super-lot event codes (plain PKs: next free id, guarded by Code) ----
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Description NVARCHAR(500), Ord INT IDENTITY(1,1));
INSERT INTO @Ev (Code, Name, Description) VALUES
    (N'ControlledRunLotJoined',        N'Super-lot Joined',        N'A LOT joined a super-lot (selected, scanned in, auto-joined or synced).'),
    (N'ControlledRunLotLeft',          N'Super-lot Left',          N'A LOT left a super-lot (removed, super-lot closed or cancelled).'),
    (N'ControlledRunLotResult',        N'Super-lot Result',        N'A result was recorded against a LOT in a super-lot.'),
    (N'ControlledRunLotResultVoided',  N'Super-lot Result Voided', N'A result recorded against a LOT in a super-lot was voided.'),
    (N'ControlledRunLotDeviation',     N'Super-lot Deviation',     N'A deviation was raised that covers a LOT in a super-lot.'),
    (N'ControlledRunLotReleased',      N'Super-lot Released',      N'A super-lot was signed released and this LOT was cleared with it.');
DECLARE @Base BIGINT = (SELECT ISNULL(MAX(Id), 0) FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @Base + ROW_NUMBER() OVER (ORDER BY e.Ord), e.Code, e.Name, e.Description
FROM @Ev e
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType x WHERE x.Code = e.Code);
GO

-- ---- 3. Flags and labels (by Code; see inventory above) ----
UPDATE Audit.LogEventType SET RepeatsLotTimeline = 1
WHERE Code IN (N'LotCreated', N'LotMoved', N'LotStatusChanged', N'LotUpdated', N'LotSplit', N'LotMerged', N'LotConsumed',
               N'DieCastPieceContributed', N'DieCastLotOpened', N'DieCastLotReleased', N'DieCastLotVoided',
               N'MachiningInPicked', N'MachiningOutCompleted')
  AND RepeatsLotTimeline = 0;

UPDATE Audit.LogEventType SET LotTimelineKind = N'CRT'
WHERE Code IN (N'CrtActivated', N'CrtCleared', N'MissedCrtInspect');
UPDATE Audit.LogEventType SET LotTimelineKind = N'Vendor return'
WHERE Code IN (N'VendorReturnMarked', N'VendorReturnConfirmed', N'VendorReturnCancelled');
UPDATE Audit.LogEventType SET LotTimelineKind = N'Rework'
WHERE Code IN (N'LotReworkStarted', N'LotReworkCompleted');
UPDATE Audit.LogEventType SET LotTimelineKind = N'Super-lot'
WHERE Code IN (N'ControlledRunLotJoined', N'ControlledRunLotLeft', N'ControlledRunLotResult',
               N'ControlledRunLotResultVoided', N'ControlledRunLotDeviation', N'ControlledRunLotReleased');
GO

IF (SELECT COUNT(*) FROM Audit.LogEventType WHERE LotTimelineKind = N'Super-lot') <> 6
   OR (SELECT COUNT(*) FROM Audit.LogEventType WHERE RepeatsLotTimeline = 1) < 13
    THROW 51000, 'Migration 0113: LogEventType flags / super-lot codes did not land.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0113_super_lot_visibility')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0113_super_lot_visibility',
            N'Super-lot piece 6: Audit.LogEventType.RepeatsLotTimeline + LotTimelineKind, flags/labels, six ControlledRunLot* codes. Do NOT deploy alone.');
GO
PRINT 'Migration 0113 (super_lot_visibility) applied.';
GO
