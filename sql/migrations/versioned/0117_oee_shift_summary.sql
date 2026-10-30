-- ============================================================
-- Migration:   0117_oee_shift_summary.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Description: OEE dashboard storage (spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              v0.3.1 sec 6.7, 7.4, D16, D18, D21):
--                1. Lots.Lot += ShiftId (FK Oee.Shift) + MintedPieceCount.
--                   Written ONCE by the mint procs (Workorder.Assembly_CompleteTray,
--                   Workorder.MachiningOut_Mint), never changed afterwards.
--                   Split / merge / rework children leave both NULL, which is
--                   what keeps them out of good (spec 6.4).
--                2. Oee.ShiftSummary -- one row per (shift, unit / station /
--                   area placement / area charge). Minutes and counts only,
--                   never percentages; every zoom pools these facts.
--                   PlannedMinutes / BaseMinutes are availability minutes (INT,
--                   as Oee.ufn_ShiftAvailability reports them); the Planned /
--                   Unplanned / NoReason downtime minutes are the ENTERED
--                   durations placed on the row (DECIMAL, the Pareto's basis).
--                3. Oee.ShiftSummaryConfig -- single row holding the
--                   configuration fingerprint the refresher compares (D22).
--
--   WHY. The v0.2 build recomputed every shift on every read (a whole-plant
--   week took 12-25 s). Per-shift figures are now computed once and stored,
--   and refreshed when their inputs change (spec 6.8).
--
--   Existing LOTs stay NULL here: versioned migrations run before the
--   repeatable functions they would need, so the one-time backfill is the
--   repeatable proc Lots.Lot_BackfillMintStamp, run by the release runbook.
--   Oee.ShiftSummary starts empty; Oee.ShiftSummary_RecomputeRange fills it.
--   ASCII only.
-- ============================================================

-- 1. Lots.Lot mint stamp
IF COL_LENGTH(N'Lots.Lot', N'ShiftId') IS NULL
    ALTER TABLE Lots.Lot ADD
        ShiftId BIGINT NULL CONSTRAINT FK_Lot_Shift REFERENCES Oee.Shift(Id);
GO
IF COL_LENGTH(N'Lots.Lot', N'MintedPieceCount') IS NULL
    ALTER TABLE Lots.Lot ADD MintedPieceCount INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_ShiftId')
    CREATE INDEX IX_Lot_ShiftId
        ON Lots.Lot (ShiftId)
        INCLUDE (MintedPieceCount, ItemId, CreatedAtTerminalId, LotOriginTypeId)
        WHERE ShiftId IS NOT NULL;
GO

-- 2. Oee.ShiftSummary
IF OBJECT_ID(N'Oee.ShiftSummary', N'U') IS NULL
BEGIN
    CREATE TABLE Oee.ShiftSummary (
        Id                        BIGINT         NOT NULL IDENTITY(1,1),
        ShiftId                   BIGINT         NOT NULL CONSTRAINT FK_ShiftSummary_Shift REFERENCES Oee.Shift(Id),
        LocationId                BIGINT         NULL     CONSTRAINT FK_ShiftSummary_Location REFERENCES Location.Location(Id),
        RowKind                   NVARCHAR(15)   NOT NULL,
        AreaFamily                NVARCHAR(10)   NULL,
        ProductionAreaId          BIGINT         NULL     CONSTRAINT FK_ShiftSummary_ProductionArea REFERENCES Location.Location(Id),
        ParentUnitLocationId      BIGINT         NULL     CONSTRAINT FK_ShiftSummary_ParentUnit REFERENCES Location.Location(Id),
        PlannedMinutes            INT            NOT NULL CONSTRAINT DF_ShiftSummary_Planned      DEFAULT (0),
        PlannedDowntimeMinutes    DECIMAL(12,2)  NOT NULL CONSTRAINT DF_ShiftSummary_PlannedDt    DEFAULT (0),
        UnplannedDowntimeMinutes  DECIMAL(12,2)  NOT NULL CONSTRAINT DF_ShiftSummary_UnplannedDt  DEFAULT (0),
        BaseMinutes               INT            NOT NULL CONSTRAINT DF_ShiftSummary_Base         DEFAULT (0),
        EffectiveUnplannedMinutes DECIMAL(12,4)  NOT NULL CONSTRAINT DF_ShiftSummary_EffUnplanned DEFAULT (0),
        DowntimeEventCount        INT            NOT NULL CONSTRAINT DF_ShiftSummary_DtCount      DEFAULT (0),
        NoReasonCount             INT            NOT NULL CONSTRAINT DF_ShiftSummary_NoReasonCnt  DEFAULT (0),
        NoReasonMinutes           DECIMAL(12,2)  NOT NULL CONSTRAINT DF_ShiftSummary_NoReasonMin  DEFAULT (0),
        Good                      BIGINT         NOT NULL CONSTRAINT DF_ShiftSummary_Good         DEFAULT (0),
        Scrap                     BIGINT         NOT NULL CONSTRAINT DF_ShiftSummary_Scrap        DEFAULT (0),
        NonRejectScrap            BIGINT         NOT NULL CONSTRAINT DF_ShiftSummary_NonReject    DEFAULT (0),
        FoundDownstreamScrap      BIGINT         NOT NULL CONSTRAINT DF_ShiftSummary_FoundDown    DEFAULT (0),
        UnplacedScrap             BIGINT         NOT NULL CONSTRAINT DF_ShiftSummary_Unplaced     DEFAULT (0),
        LastToolId                BIGINT         NULL     CONSTRAINT FK_ShiftSummary_Tool REFERENCES Tools.Tool(Id),
        IsActive                  BIT            NOT NULL,
        ComputedAt                DATETIME2(3)   NOT NULL,
        InputFingerprint          VARBINARY(32)  NOT NULL,
        CONSTRAINT PK_ShiftSummary PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ShiftSummary_RowKind CHECK (RowKind IN (N'Unit', N'Station', N'AreaPlacement', N'AreaCharge'))
    );

    -- One row per shift per placement; AreaCharge rows have LocationId NULL and
    -- are unique per family.
    CREATE UNIQUE INDEX UX_ShiftSummary_Key
        ON Oee.ShiftSummary (ShiftId, RowKind, AreaFamily, LocationId);
END
GO

-- 3. Oee.ShiftSummaryConfig (single row)
IF OBJECT_ID(N'Oee.ShiftSummaryConfig', N'U') IS NULL
BEGIN
    CREATE TABLE Oee.ShiftSummaryConfig (
        Id                BIGINT         NOT NULL,
        ConfigFingerprint VARBINARY(32)  NULL,
        ConfigChangedAt   DATETIME2(3)   NULL,
        CheckedAt         DATETIME2(3)   NULL,
        CONSTRAINT PK_ShiftSummaryConfig PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ShiftSummaryConfig_SingleRow CHECK (Id = 1)
    );
END
GO
IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSummaryConfig)
    INSERT INTO Oee.ShiftSummaryConfig (Id, ConfigFingerprint, ConfigChangedAt, CheckedAt)
    VALUES (1, NULL, NULL, NULL);
GO

IF COL_LENGTH(N'Lots.Lot', N'MintedPieceCount') IS NULL
   OR OBJECT_ID(N'Oee.ShiftSummary', N'U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM Oee.ShiftSummaryConfig)
    THROW 51000, 'Migration 0117: Lot mint columns, Oee.ShiftSummary or Oee.ShiftSummaryConfig did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0117_oee_shift_summary')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0117_oee_shift_summary',
            N'OEE dashboard storage: Lots.Lot += ShiftId/MintedPieceCount (mint stamp), Oee.ShiftSummary, Oee.ShiftSummaryConfig. Backfill via Lots.Lot_BackfillMintStamp; fill via Oee.ShiftSummary_RecomputeRange.');
GO
PRINT 'Migration 0117 (oee_shift_summary) applied.';
GO
