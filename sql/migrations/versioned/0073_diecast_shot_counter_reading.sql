-- ============================================================
-- Migration:   0073_diecast_shot_counter_reading.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-09
-- Description: Die-cast SHOT-READING CHAIN (spec
--              docs/superpowers/specs/2026-09-09-diecast-shot-reading-chain-design.md).
--
--              The press counter resets each shift, so the number the operator
--              types is a READING, not an increment. Every cavity carries a
--              credited-through watermark starting at 0 each shift, and a
--              basket's credit is (reading - watermark). The reading typed at a
--              release does double duty: it closes the outgoing basket and
--              becomes the incoming basket's watermark.
--
--              Adds Workorder.DieCastContribution.ShotCounterReading -- the
--              press counter reading at which that ledger row was taken. Both
--              watermarks derive from this one column:
--                * CAVITY watermark, scoped (ToolCavityId, ShiftId,
--                  CellLocationId) -> the per-basket credit. Scoping by PRESS
--                  is what makes a die move to another press, and a changeover
--                  to another die on the same press, reset the chain with no
--                  special-casing: a different press is a different counter
--                  space, and a different die has different ToolCavity rows.
--                * DIE watermark, scoped (ToolId, ShiftId, CellLocationId) ->
--                  the Tools.Tool.ShotCount increment.
--
--              BACKFILL. Every pre-existing row has a NULL reading, which the
--              watermark functions would read as 0 -- so the first entry after
--              deploy would credit each open basket the FULL reading and
--              double-count anything already recorded in that shift.
--
--              This backfills EVERY NULL reading, not just open shifts,
--              because operators may retroactively enter the previous two
--              shifts (spec E9) and a closed shift can therefore still be read.
--
--              The backfill is a running sum of PieceDelta per
--              (cavity, shift, press) in event order. That is EXACTLY right
--              for the common case -- one basket, one entry per shift, one
--              part per shot -- and approximate only where the pre-change
--              model was already wrong (a cavity that rolled mid-shift). It
--              cannot be recovered more accurately: the true readings were
--              never recorded.
--
--              The row count is PRINTed. On a database quiesced at a shift
--              change it should print 0.
--
--              Additive. Idempotent-guarded; no explicit transaction (repo
--              convention -- see 0067).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0073_diecast_shot_counter_reading')
BEGIN
    PRINT 'Migration 0073 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Workorder.DieCastContribution.ShotCounterReading
-- ============================================================
IF COL_LENGTH('Workorder.DieCastContribution', 'ShotCounterReading') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD ShotCounterReading INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_DieCastContribution_ReadingNonNeg')
    ALTER TABLE Workorder.DieCastContribution
        ADD CONSTRAINT CK_DieCastContribution_ReadingNonNeg
            CHECK (ShotCounterReading IS NULL OR ShotCounterReading >= 0);
GO

-- Watermarks are MAX(reading) filtered by shift + press, per cavity or per die.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_DieCastContribution_Shift_Cell_Reading'
                 AND object_id = OBJECT_ID(N'Workorder.DieCastContribution'))
    CREATE NONCLUSTERED INDEX IX_DieCastContribution_Shift_Cell_Reading
        ON Workorder.DieCastContribution (ShiftId, CellLocationId)
        INCLUDE (LotId, ShotCounterReading);
GO

-- ============================================================
-- 2. Backfill every NULL reading (see header for why all shifts)
-- ============================================================
DECLARE @Before INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ShotCounterReading IS NULL);

;WITH Ordered AS (
    SELECT c.Id,
           SUM(c.PieceDelta) OVER (
               PARTITION BY l.ToolCavityId, c.ShiftId, ISNULL(c.CellLocationId, -1)
               ORDER BY c.EventAt, c.Id
               ROWS UNBOUNDED PRECEDING
           ) AS RunningReading
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE c.ShotCounterReading IS NULL
)
UPDATE c
SET ShotCounterReading = o.RunningReading
FROM Workorder.DieCastContribution c
INNER JOIN Ordered o ON o.Id = c.Id;

DECLARE @Filled INT = @@ROWCOUNT;

-- Rows whose LOT has since been hard-deleted cannot be reconstructed; anchor
-- them at 0 so no watermark is ever left NULL.
UPDATE Workorder.DieCastContribution SET ShotCounterReading = 0 WHERE ShotCounterReading IS NULL;
DECLARE @Orphans INT = @@ROWCOUNT;

PRINT '0073 backfill: ' + CAST(@Before AS NVARCHAR(20)) + ' row(s) had a NULL reading; '
    + CAST(@Filled AS NVARCHAR(20)) + ' reconstructed from PieceDelta, '
    + CAST(@Orphans AS NVARCHAR(20)) + ' orphaned row(s) anchored at 0.';
PRINT '0073: on a database quiesced at a shift change this should read 0 / 0 / 0.';
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0073_diecast_shot_counter_reading')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0073_diecast_shot_counter_reading',
        N'Die-cast shot-reading chain: Workorder.DieCastContribution.ShotCounterReading INT NULL + non-negative CHECK + (ShiftId, CellLocationId) index. Cavity and die watermarks derive from it, scoped by press so a die move or changeover resets the chain. Backfills every NULL reading as a running sum of PieceDelta per (cavity, shift, press).'
    );
GO

PRINT 'Migration 0073 completed: Workorder.DieCastContribution.ShotCounterReading.';
GO
