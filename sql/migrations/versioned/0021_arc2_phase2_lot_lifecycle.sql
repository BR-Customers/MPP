-- ============================================================
-- Migration: 0021_arc2_phase2_lot_lifecycle
-- Purpose:   Arc 2 Phase 2 LOT lifecycle SQL foundation -- the complete
--            LOT mutation / genealogy / label / pause surface (tables only;
--            the ~15 stored procedures land as R__Lots_*.sql repeatables).
--
--            Tables created (all guarded IF OBJECT_ID(...) IS NULL):
--              * Lots.LotGenealogy        -- append-only genealogy edge log.
--                                            BORN PARTITIONED on EventAt
--                                            (ps_MonthlyUtc; 20-yr Honda class;
--                                            mirrors LotStatusHistory pattern).
--                                            Registered in PartitionRetention
--                                            @ 240 months.
--              * Lots.LotAttributeChange  -- append-only field-diff log
--                                            (not partitioned).
--              * Lots.LotLabel            -- append-only LTT print log
--                                            (not partitioned).
--              * Lots.PauseEvent          -- operator pause place/resume
--                                            lifecycle (not partitioned);
--                                            filtered-unique open-pause
--                                            invariant + indicator indexes.
--              * Lots.LabelTemplate       -- 1:1 active ASCII ZPL body per
--                                            LabelTypeCode (not partitioned).
--
--            Seeds:
--              * Audit.LogEventType  -- LotUpdated/LotPaused/LotResumed (new;
--                                       LotSplit/LotMerged/LotConsumed/
--                                       LabelPrinted already seeded in 0001).
--              * Audit.LogEntityType -- LotLabel/PauseEvent/LotGenealogy (new).
--              * Lots.LabelTemplate  -- one ASCII ZPL body per LabelTypeCode.
--
--            Not touched: Lots.v_LotDerivedQuantities and the
--            Lot.TotalInProcess / Lot.InventoryAvailable materialized columns
--            already shipped in 0020.
--
-- Partition notes: LotGenealogy joins the born-partitioned 20-yr Honda family
--   on ps_MonthlyUtc(EventAt) -- aligned composite PK NONCLUSTERED (Id, EventAt)
--   + a clustered hot path on (ParentLotId, EventAt) + an aligned secondary on
--   (ChildLotId, EventAt). The other four tables are left non-partitioned in
--   Phase 2 (lower volume, no incoming bare-Id FK pressure).
--
-- Reference column shapes verified on disk:
--   * Audit.LogEventType / LogEntityType (0001): Id BIGINT PK (NOT IDENTITY) ->
--     explicit Ids supplied below, guarded IF NOT EXISTS like 0020.
--   * Lots.LabelTypeCode (0004): columns Id/Code/Name only -- NO DeprecatedAt,
--     so the LabelTemplate seed has no LabelTypeCode-side DeprecatedAt predicate.
--   * Lots.GenealogyRelationshipType (0004): Split=1, Merge=2, Consumption=3.
-- ============================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO


-- ============================================================
-- == TABLES ==================================================
-- ============================================================

-- ---- Lots.LotGenealogy (BORN PARTITIONED on EventAt) ----
-- Append-only edge table (FDS-05-016). 20-yr Honda class -> aligned composite
-- PK NONCLUSTERED (Id, EventAt) ON ps_MonthlyUtc(EventAt) + clustered hot path
-- (ParentLotId, EventAt) + aligned secondary (ChildLotId, EventAt) for the
-- child->parent walk. Maintained transactionally beside LotGenealogyClosure.
IF OBJECT_ID(N'Lots.LotGenealogy', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotGenealogy (
        Id                 BIGINT        NOT NULL IDENTITY(1,1),
        ParentLotId        BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        ChildLotId         BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        RelationshipTypeId BIGINT        NOT NULL REFERENCES Lots.GenealogyRelationshipType(Id),
        PieceCount         INT           NULL,
        EventUserId        BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT        NULL     REFERENCES Location.Location(Id),
        EventAt            DATETIME2(3)  NOT NULL CONSTRAINT DF_LotGenealogy_EventAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotGenealogy PRIMARY KEY NONCLUSTERED (Id, EventAt)
            ON ps_MonthlyUtc(EventAt)
    );

    CREATE CLUSTERED INDEX CIX_LotGenealogy_ParentEventAt
        ON Lots.LotGenealogy (ParentLotId, EventAt)
        ON ps_MonthlyUtc(EventAt);

    CREATE INDEX IX_LotGenealogy_Child
        ON Lots.LotGenealogy (ChildLotId, EventAt)
        ON ps_MonthlyUtc(EventAt);
END
GO

-- Register LotGenealogy for 240-month (20-yr Honda) sliding-window age-out.
IF NOT EXISTS (SELECT 1 FROM Audit.PartitionRetention WHERE SchemaName = N'Lots' AND TableName = N'LotGenealogy')
    INSERT INTO Audit.PartitionRetention (SchemaName, TableName, RetentionMonths, Description)
    VALUES (N'Lots', N'LotGenealogy', 240, N'Append-only LOT genealogy edge log. Honda 20-yr traceability retention class.');
GO


-- ---- Lots.LotAttributeChange (NOT partitioned) ----
-- Append-only field-diff log (FDS-05-021). Low volume in Phase 2; index on
-- (LotId, ChangedAt) for the per-LOT history read.
IF OBJECT_ID(N'Lots.LotAttributeChange', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotAttributeChange (
        Id                 BIGINT        NOT NULL IDENTITY(1,1),
        LotId              BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        AttributeName      NVARCHAR(100) NOT NULL,
        OldValue           NVARCHAR(500) NULL,
        NewValue           NVARCHAR(500) NULL,
        ChangedByUserId    BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT        NULL     REFERENCES Location.Location(Id),
        ChangedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_LotAttributeChange_ChangedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotAttributeChange PRIMARY KEY NONCLUSTERED (Id)
    );

    CREATE INDEX IX_LotAttributeChange_Lot
        ON Lots.LotAttributeChange (LotId, ChangedAt);
END
GO


-- ---- Lots.LotLabel (NOT partitioned) ----
-- Append-only LTT print log (FDS-05-019). ParentLotId NULL for non-sublot
-- labels (set for the FDS-05-024 sublot rule). ZplContent is the rendered,
-- ready-to-dispatch ZPL string.
IF OBJECT_ID(N'Lots.LotLabel', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotLabel (
        Id                 BIGINT         NOT NULL IDENTITY(1,1),
        LotId              BIGINT         NOT NULL REFERENCES Lots.Lot(Id),
        LabelTypeCodeId    BIGINT         NOT NULL REFERENCES Lots.LabelTypeCode(Id),
        PrintReasonCodeId  BIGINT         NOT NULL REFERENCES Lots.PrintReasonCode(Id),
        ParentLotId        BIGINT         NULL     REFERENCES Lots.Lot(Id),
        ZplContent         NVARCHAR(MAX)  NOT NULL,
        PrinterName        NVARCHAR(100)  NULL,
        PrintedByUserId    BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT         NULL     REFERENCES Location.Location(Id),
        PrintedAt          DATETIME2(3)   NOT NULL CONSTRAINT DF_LotLabel_PrintedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotLabel PRIMARY KEY NONCLUSTERED (Id)
    );

    CREATE INDEX IX_LotLabel_Lot
        ON Lots.LotLabel (LotId, PrintedAt);
END
GO


-- ---- Lots.PauseEvent (NOT partitioned) ----
-- Operator pause place/resume lifecycle (OI-21 / FDS-05-038), mirrors
-- Quality.HoldEvent. Filtered-unique guarantees at most one open pause per
-- (LotId, LocationId); the same LOT MAY be paused at multiple Cells at once.
IF OBJECT_ID(N'Lots.PauseEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.PauseEvent (
        Id              BIGINT        NOT NULL IDENTITY(1,1),
        LotId           BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        LocationId      BIGINT        NOT NULL REFERENCES Location.Location(Id),
        PausedByUserId  BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
        PausedAt        DATETIME2(3)  NOT NULL CONSTRAINT DF_PauseEvent_PausedAt DEFAULT SYSUTCDATETIME(),
        PausedReason    NVARCHAR(500) NULL,
        ResumedByUserId BIGINT        NULL     REFERENCES Location.AppUser(Id),
        ResumedAt       DATETIME2(3)  NULL,
        ResumedRemarks  NVARCHAR(500) NULL,
        CONSTRAINT PK_PauseEvent PRIMARY KEY NONCLUSTERED (Id),
        CONSTRAINT CK_PauseEvent_ResumePaired CHECK (
            (ResumedByUserId IS NULL     AND ResumedAt IS NULL) OR
            (ResumedByUserId IS NOT NULL AND ResumedAt IS NOT NULL))
    );

    -- B3 open-event invariant: at most one open pause per (LotId, LocationId).
    CREATE UNIQUE INDEX UQ_PauseEvent_OpenLotLocation
        ON Lots.PauseEvent (LotId, LocationId) WHERE ResumedAt IS NULL;

    -- Paused-LOT indicator counter (open pauses at a Cell).
    CREATE INDEX IX_PauseEvent_OpenByLocation
        ON Lots.PauseEvent (LocationId) WHERE ResumedAt IS NULL;

    -- Per-LOT pause history.
    CREATE INDEX IX_PauseEvent_Lot
        ON Lots.PauseEvent (LotId, PausedAt DESC);  -- DESC: per-LOT pause history reads newest-first
END
GO


-- ---- Lots.LabelTemplate (NOT partitioned) ----
-- 1:1 active ASCII ZPL body per LabelTypeCode. ZplBody uses {Placeholder}
-- tokens resolved at print time: {LotName} {ParentLotNumber} {ItemCode}
-- {PieceCount} {PrintedAt}. Filtered-unique enforces one active template per
-- label type.
-- NOTE: CreatedByUserId intentionally omitted in Phase 2 (templates seeded directly,
-- no writer proc yet). A future writer-proc migration MUST add it as NULL (not NOT NULL)
-- so it does not block the existing seed rows.
IF OBJECT_ID(N'Lots.LabelTemplate', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LabelTemplate (
        Id              BIGINT         NOT NULL IDENTITY(1,1),
        LabelTypeCodeId BIGINT         NOT NULL REFERENCES Lots.LabelTypeCode(Id),
        ZplBody         NVARCHAR(MAX)  NOT NULL,
        DeprecatedAt    DATETIME2(3)   NULL,
        CreatedAt       DATETIME2(3)   NOT NULL CONSTRAINT DF_LabelTemplate_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LabelTemplate PRIMARY KEY NONCLUSTERED (Id)
    );

    CREATE UNIQUE INDEX UQ_LabelTemplate_ActiveType
        ON Lots.LabelTemplate (LabelTypeCodeId) WHERE DeprecatedAt IS NULL;
END
GO


-- ============================================================
-- == SEEDS ===================================================
-- ============================================================
-- Audit.LogEventType / LogEntityType use explicit Ids (NOT IDENTITY). Existing
-- max: LogEventType Id 28, LogEntityType Id 41 (verified across 0001..0020).
-- LotSplit (7) / LotMerged (8) / LotConsumed (9) / LabelPrinted (17) already
-- seeded in 0001 -- only LotUpdated / LotPaused / LotResumed are new event
-- codes. Guarded IF NOT EXISTS on Code so a re-run is a no-op.

-- ---- New operational LogEventType codes (Ids 29/30/31) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 29 OR Code = N'LotUpdated')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (29, N'LotUpdated', N'LOT Updated', N'A LOT header attribute was updated (Lot_Update / Lot_UpdateAttribute).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 30 OR Code = N'LotPaused')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (30, N'LotPaused', N'LOT Paused', N'An operator placed a pause on a LOT at a location (LotPause_Place).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 31 OR Code = N'LotResumed')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (31, N'LotResumed', N'LOT Resumed', N'An operator resumed a paused LOT (LotPause_Resume).');
GO

-- ---- New LogEntityType codes (Ids 42/43/44) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 42 OR Code = N'LotLabel')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (42, N'LotLabel', N'LOT Label', N'Printed LTT label record (Lots.LotLabel).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 43 OR Code = N'PauseEvent')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (43, N'PauseEvent', N'Pause Event', N'LOT pause place/resume lifecycle event (Lots.PauseEvent).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 44 OR Code = N'LotGenealogy')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (44, N'LotGenealogy', N'LOT Genealogy', N'Genealogy edge record (Lots.LotGenealogy).');
GO

-- ---- LabelTemplate: one ASCII ZPL body per LabelTypeCode ----
-- Tokens resolved at print time: {LotName} {ParentLotNumber} {ItemCode}
-- {PieceCount} {PrintedAt}. LabelTypeCode has no DeprecatedAt column (verified
-- in 0004) -> no LabelTypeCode-side active predicate. Insert-if-missing by
-- "already has an active template" so a re-run is a no-op.
INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody)
SELECT ltc.Id,
       N'^XA^FO40,40^A0N,40,40^FDLOT {LotName}^FS' +
       N'^FO40,90^A0N,30,30^FDItem {ItemCode}  Qty {PieceCount}^FS' +
       N'^FO40,130^A0N,30,30^FDParent {ParentLotNumber}^FS' +
       N'^FO40,170^A0N,24,24^FD{PrintedAt}^FS' +
       N'^FO40,210^BY2^BCN,80,Y,N,N^FD{LotName}^FS^XZ'
FROM Lots.LabelTypeCode ltc
WHERE NOT EXISTS (SELECT 1 FROM Lots.LabelTemplate t
                  WHERE t.LabelTypeCodeId = ltc.Id AND t.DeprecatedAt IS NULL);
GO


-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0021_arc2_phase2_lot_lifecycle')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0021_arc2_phase2_lot_lifecycle',
        N'Arc 2 Phase 2: LotGenealogy (born-partitioned), LotAttributeChange, LotLabel, PauseEvent, LabelTemplate + LogEventType/LogEntityType/LabelTemplate seeds.'
    );
GO
PRINT 'Migration 0021 (Arc 2 Phase 2 LOT lifecycle) applied.';
GO
