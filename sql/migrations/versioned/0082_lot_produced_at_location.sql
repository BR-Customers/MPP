-- ============================================================
-- Migration:   0082_lot_produced_at_location.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-14
-- Description: Lots.Lot.ProducedAtLocationId -- the die cast machine that
--              produced this LOT.
--
--              WHY. In normal production the machine needs no column: a die
--              cast terminal's PARENT is the machine (DC1-M01-T1 -> DC1-M01),
--              so Lot.CreatedAtTerminalId answers "which machine cast this".
--
--              The inventory cutover scan breaks that implication. The basket
--              was cast weeks ago and the scan happens at a MACHINING terminal,
--              so CreatedAtTerminalId records the machining terminal and the
--              casting machine survives only on the paper tag in the operator's
--              hand. The cutover window is the one chance to capture it.
--
--              WHY NOT DieNumber. That column is the LEGACY DIE, superseded by
--              the ToolId FK in v1.9 and scheduled for removal once all writers
--              move to the FK. A machine stored there would have to be
--              untangled by the removal migration.
--
--              WHAT. BIGINT NULL FK -> Location.Location(Id). NULL for every
--              LOT born at a die cast terminal and for every received
--              purchased component. Lots.Lot is the unpartitioned header table,
--              so adding a nullable column is metadata-only.
--
--              NO INDEX -- nothing queries by machine yet. NO BACKFILL -- LOTs
--              from the cutover releases already shipped never captured one.
-- ============================================================

-- ---- 1. The column ----
IF COL_LENGTH('Lots.Lot', 'ProducedAtLocationId') IS NULL
    ALTER TABLE Lots.Lot
        ADD ProducedAtLocationId BIGINT NULL
            CONSTRAINT FK_Lot_ProducedAtLocation REFERENCES Location.Location(Id);
GO

-- ---- 2. Report, so a failed add is visible at deploy ----
DECLARE @Present NVARCHAR(20) =
    CASE WHEN COL_LENGTH('Lots.Lot', 'ProducedAtLocationId') IS NOT NULL
         THEN N'present' ELSE N'MISSING' END;
PRINT 'Lots.Lot.ProducedAtLocationId: ' + @Present;
GO

-- ---- 3. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0082_lot_produced_at_location')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0082_lot_produced_at_location',
            N'Lots.Lot.ProducedAtLocationId (BIGINT NULL, FK -> Location.Location) -- the die cast machine that produced a LOT. Written only by the inventory cutover scan, where the creating terminal is a machining terminal and cannot imply the casting machine. Not DieNumber, which is the legacy die column slated for removal.');
GO
PRINT 'Migration 0082 (lot_produced_at_location) applied.';
GO
