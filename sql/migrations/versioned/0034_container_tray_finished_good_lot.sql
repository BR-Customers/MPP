-- ============================================================
-- Migration:   0034_container_tray_finished_good_lot.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-06
-- Description: Arc 2 machining/assembly flow reconciliation (Spec 2, Task A1).
--              Assembly-out now mints a finished-good LOT where tray = LOT
--              (customer discovery). Adds Lots.ContainerTray.FinishedGoodLotId
--              (BIGINT NULL FK -> Lots.Lot) with a filtered UNIQUE index on the
--              non-null values to enforce the 1:1 tray<->LOT relationship.
--              Nullable here to keep the existing 0028 trays green until they
--              route through the Assembly_CompleteTray orchestrator (Task A3); a
--              later cleanup can tighten to NOT NULL once every tray is minted via
--              the orchestrator.
-- ============================================================

IF COL_LENGTH(N'Lots.ContainerTray', N'FinishedGoodLotId') IS NULL
    ALTER TABLE Lots.ContainerTray ADD FinishedGoodLotId BIGINT NULL
        CONSTRAINT FK_ContainerTray_FinishedGoodLot REFERENCES Lots.Lot(Id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerTray_FinishedGoodLot')
    CREATE UNIQUE INDEX UQ_ContainerTray_FinishedGoodLot
        ON Lots.ContainerTray (FinishedGoodLotId) WHERE FinishedGoodLotId IS NOT NULL;
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0034_container_tray_finished_good_lot')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0034_container_tray_finished_good_lot',
        N'Spec 2 A1: add Lots.ContainerTray.FinishedGoodLotId (BIGINT NULL FK -> Lots.Lot) + filtered UNIQUE index for the 1:1 tray<->finished-good-LOT link (assembly-out mints a FG LOT).');
GO

PRINT 'Migration 0034 (ContainerTray.FinishedGoodLotId) applied.';
GO
