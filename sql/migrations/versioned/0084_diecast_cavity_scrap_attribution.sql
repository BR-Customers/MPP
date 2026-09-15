-- ============================================================
-- Migration:   0084_diecast_cavity_scrap_attribution.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-14
-- Description: Die-cast scrap becomes a fact about (Shift, Press, Tool, Cavity,
--              Part) with the LOT optional. Spec:
--              docs/superpowers/specs/2026-09-14-diecast-quantity-and-scrap-model-design.md
--
--              1. Workorder.RejectEvent.LotId NOT NULL -> NULL, so a cavity
--                 with no basket can be scrapped at all. LotId is the leading
--                 key of a CLUSTERED index on a PARTITIONED table, so this is
--                 drop-FK / drop-index / alter / rebuild. THE REBUILD MUST
--                 STAY ON ps_MonthlyUtc(RecordedAt): every index on this table
--                 is partition-aligned and sliding-window TRUNCATE retention
--                 (B2) depends on that. Rebuilding on PRIMARY breaks partition
--                 maintenance silently.
--
--              2. RejectEvent gains ItemId / ToolId / ToolCavityId / ShiftId /
--                 CellLocationId. ItemId is stamped, not derived: two reject
--                 reports reach the part via INNER JOIN Lots.Lot, and an inner
--                 join on a NULL key DROPS THE ROW -- lot-free scrap would
--                 vanish from the Part Matrix and the Transaction Detail with
--                 no error. ToolId is denormalised for the same reason one
--                 level up: several dies make the same part number and are
--                 distinguishable only by code.
--
--              3. Workorder.DieCastContribution gains ToolCavityId +
--                 VarianceReasonId + VarianceNote. Its LotId STAYS NOT NULL --
--                 a basketless cavity must not advance its shot watermark,
--                 because those castings go into the next physical basket and
--                 crediting them there is correct (spec 3.6). Unpartitioned
--                 table, so a plain ALTER.
--
--              4. Workorder.DieCastVarianceReason, shaped like
--                 DieCastCounterAnchorReason (0074).
--
--              5. Quality.DefectCode DC-999 'Warmup'. Prod carries it and this
--                 repo never has; it is also uncategorised and counted inside
--                 the reject percentage. Added + classified here AND in seed
--                 030 (0048 / 0067 / 0075 precedent: a reset runs migrations
--                 before seeds, an in-place upgrade never re-runs seeds).
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0084_diecast_cavity_scrap_attribution')
BEGIN PRINT 'Migration 0084 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. RejectEvent: new attribution columns ----
IF COL_LENGTH('Workorder.RejectEvent', 'ItemId')         IS NULL ALTER TABLE Workorder.RejectEvent ADD ItemId         BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ToolId')         IS NULL ALTER TABLE Workorder.RejectEvent ADD ToolId         BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ToolCavityId')   IS NULL ALTER TABLE Workorder.RejectEvent ADD ToolCavityId   BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ShiftId')        IS NULL ALTER TABLE Workorder.RejectEvent ADD ShiftId        BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'CellLocationId') IS NULL ALTER TABLE Workorder.RejectEvent ADD CellLocationId BIGINT NULL;
GO

-- ---- 2. Backfill ItemId from the LOT before anything can be written NULL ----
UPDATE re SET re.ItemId = l.ItemId
FROM Workorder.RejectEvent re
INNER JOIN Lots.Lot l ON l.Id = re.LotId
WHERE re.ItemId IS NULL;
GO

-- ---- 3. RejectEvent.LotId -> NULLable ----
-- LotId is the leading key of CIX_RejectEvent_LotRecordedAt (CLUSTERED, on
-- ps_MonthlyUtc). SQL Server will not ALTER COLUMN an indexed column's
-- nullability in place, so: drop FK, drop index, alter, rebuild ALIGNED, re-add.
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Lot')
    ALTER TABLE Workorder.RejectEvent DROP CONSTRAINT FK_RejectEvent_Lot;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'CIX_RejectEvent_LotRecordedAt'
             AND object_id = OBJECT_ID(N'Workorder.RejectEvent'))
    DROP INDEX CIX_RejectEvent_LotRecordedAt ON Workorder.RejectEvent;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent')
             AND name = N'LotId' AND is_nullable = 0)
    ALTER TABLE Workorder.RejectEvent ALTER COLUMN LotId BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'CIX_RejectEvent_LotRecordedAt'
                 AND object_id = OBJECT_ID(N'Workorder.RejectEvent'))
    CREATE CLUSTERED INDEX CIX_RejectEvent_LotRecordedAt
        ON Workorder.RejectEvent (LotId, RecordedAt)
        ON ps_MonthlyUtc(RecordedAt);   -- ALIGNED. Do not change to PRIMARY.
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Lot')
    ALTER TABLE Workorder.RejectEvent
        ADD CONSTRAINT FK_RejectEvent_Lot FOREIGN KEY (LotId) REFERENCES Lots.Lot(Id);
GO

-- ---- 4. RejectEvent FKs + the cavity-keyed read path (B8 filtered index) ----
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Item')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_Item
        FOREIGN KEY (ItemId) REFERENCES Parts.Item(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Tool')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_Tool
        FOREIGN KEY (ToolId) REFERENCES Tools.Tool(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_ToolCavity')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_ToolCavity
        FOREIGN KEY (ToolCavityId) REFERENCES Tools.ToolCavity(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Shift')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_Shift
        FOREIGN KEY (ShiftId) REFERENCES Oee.Shift(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_CellLocation')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_CellLocation
        FOREIGN KEY (CellLocationId) REFERENCES Location.Location(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_RejectEvent_ShiftCavity'
                 AND object_id = OBJECT_ID(N'Workorder.RejectEvent'))
    CREATE INDEX IX_RejectEvent_ShiftCavity
        ON Workorder.RejectEvent (ShiftId, ToolCavityId, RecordedAt)
        WHERE ShiftId IS NOT NULL
        ON ps_MonthlyUtc(RecordedAt);
GO

-- ---- 5. DieCastVarianceReason ----
IF OBJECT_ID(N'Workorder.DieCastVarianceReason', N'U') IS NULL
    CREATE TABLE Workorder.DieCastVarianceReason (
        Id           BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code         NVARCHAR(50)  NOT NULL,
        Name         NVARCHAR(100) NOT NULL,
        RequiresNote BIT           NOT NULL CONSTRAINT DF_DCVR_RequiresNote DEFAULT 0,
        SortOrder    INT           NOT NULL CONSTRAINT DF_DCVR_SortOrder DEFAULT 0,
        CONSTRAINT UQ_DieCastVarianceReason_Code UNIQUE (Code)
    );
GO
MERGE Workorder.DieCastVarianceReason AS t
USING (VALUES
    (N'MiscountedBasket',     N'Basket count corrected',          0, 1),
    (N'CounterSuspect',       N'Press counter reading suspect',   0, 2),
    (N'ScrapNotRecorded',     N'Scrap produced but not recorded', 0, 3),
    (N'PartsRemovedFromLine', N'Parts removed from the line',     1, 4),
    (N'Unknown',              N'Unknown',                         1, 5)
) AS s (Code, Name, RequiresNote, SortOrder)
ON t.Code = s.Code
WHEN MATCHED THEN UPDATE SET t.Name = s.Name, t.RequiresNote = s.RequiresNote, t.SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (Code, Name, RequiresNote, SortOrder)
                      VALUES (s.Code, s.Name, s.RequiresNote, s.SortOrder);
GO

-- ---- 6. DieCastContribution: stamped cavity + disposition ----
-- LotId deliberately UNCHANGED (NOT NULL) -- spec 3.6.
IF COL_LENGTH('Workorder.DieCastContribution', 'ToolCavityId') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD ToolCavityId BIGINT NULL;
GO
IF COL_LENGTH('Workorder.DieCastContribution', 'VarianceReasonId') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD VarianceReasonId BIGINT NULL;
GO
IF COL_LENGTH('Workorder.DieCastContribution', 'VarianceNote') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD VarianceNote NVARCHAR(500) NULL;
GO
UPDATE c SET c.ToolCavityId = l.ToolCavityId
FROM Workorder.DieCastContribution c
INNER JOIN Lots.Lot l ON l.Id = c.LotId
WHERE c.ToolCavityId IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DieCastContribution_ToolCavity')
    ALTER TABLE Workorder.DieCastContribution ADD CONSTRAINT FK_DieCastContribution_ToolCavity
        FOREIGN KEY (ToolCavityId) REFERENCES Tools.ToolCavity(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DieCastContribution_VarianceReason')
    ALTER TABLE Workorder.DieCastContribution ADD CONSTRAINT FK_DieCastContribution_VarianceReason
        FOREIGN KEY (VarianceReasonId) REFERENCES Workorder.DieCastVarianceReason(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastContribution_Cavity'
                 AND object_id = OBJECT_ID(N'Workorder.DieCastContribution'))
    CREATE INDEX IX_DieCastContribution_Cavity
        ON Workorder.DieCastContribution (ToolCavityId, ShiftId);
GO

-- ---- 7. DC-999 Warmup ----
DECLARE @ocDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @cpDieCast BIGINT = (SELECT Id FROM Quality.ChargeToParty    WHERE Code = N'DieCast');

IF NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = N'DC-999')
    INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused)
    VALUES (N'DC-999', N'Warmup', @ocDieCast, 0);

UPDATE Quality.DefectCode
   SET OperationCategoryId = @ocDieCast,
       ChargeToPartyId     = @cpDieCast,
       IsNonRejectScrap    = 1
 WHERE Code = N'DC-999';
GO

-- ---- 8. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0084_diecast_cavity_scrap_attribution')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0084_diecast_cavity_scrap_attribution',
            N'Die-cast scrap attributed to (Shift, Press, Tool, Cavity, Part): RejectEvent.LotId nullable (clustered index rebuilt aligned) plus ItemId/ToolId/ToolCavityId/ShiftId/CellLocationId; DieCastContribution gains ToolCavityId + variance disposition (LotId stays NOT NULL per spec 3.6); Workorder.DieCastVarianceReason seeded; DC-999 Warmup added, categorised DieCast, charged to DieCast, flagged non-reject scrap.');
GO
PRINT 'Migration 0084 (diecast_cavity_scrap_attribution) applied.';
GO
