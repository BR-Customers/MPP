-- ============================================================
-- Migration:   0080_cutover_entry_route_and_cast_date.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-12
-- Description: Inventory cutover scan support. Three nullable columns; every
--              existing row keeps today's behaviour and nothing is backfilled.
--
--              WHY. Cutting a Machining & Assembly line over to Ignition means
--              counting the physical inventory standing at that line into the
--              new MES. There is no usable electronic source: the legacy
--              SparkMES-lineage MES covers only about half the lines and its
--              data is materially out of step with the floor, and the remaining
--              lines are tracked in a separate, hand-maintained database. So
--              the count is physical -- an operator scans each LTT.
--
--              Lots.Lot.EntryRouteSequence -- the route step at which a LOT
--              joined its route. Steps with a lower SequenceNumber are NOT part
--              of that LOT's journey and are never pending
--              (Lots.ufn_NextPendingRouteStep). NULL = entered at the route
--              start, which is every normally minted LOT. Without this, a
--              casting counted in at Machining IN would surface in the Trim
--              queues, because its first pending Advance step is TrimIn.
--              The alternative -- writing synthetic TrimIn / TrimOut
--              ProductionEvent rows -- was rejected: it asserts that a trim
--              operator ran that basket on our system at a timestamp, which is
--              false, and it would flow into OEE and operator attribution.
--
--              Lots.Lot.CastDate -- the cast date read off the physical LTT at
--              scan time. Drives real FIFO for migrated stock via
--              COALESCE(CastDate, last LotMovement). NULL for normally minted
--              LOTs, whose arrival order already IS their FIFO order.
--              Deliberately NOT backdated onto Lots.LotMovement.MovedAt: that
--              table is partitioned on MovedAt under the B1/B2 sliding-window
--              TRUNCATE retention, so a backdated row lands in a partition
--              maintenance is designed to sweep, and the LOT's FIFO position
--              would then change silently with no error and no audit trail.
--              Lots.Lot is not partitioned.
--
--              Location.Location.DefaultStockLocationId -- on a Line, where
--              inventory scanned for that line is deposited. Self-FK; NULL =
--              the line itself, which is how M&A inventory works today (LOTs
--              are line-resident). Present so warehouse-held stock for a line
--              becomes expressible later without reworking the scan surface.
--
--              All three are nullable with no default, so each ALTER is
--              metadata-only: online, no table rewrite, no backfill.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0080_cutover_entry_route_and_cast_date')
BEGIN PRINT 'Migration 0080 already applied -- skipping.'; RETURN; END
GO

IF COL_LENGTH('Lots.Lot', 'EntryRouteSequence') IS NULL
    ALTER TABLE Lots.Lot ADD EntryRouteSequence INT NULL;
GO

IF COL_LENGTH('Lots.Lot', 'CastDate') IS NULL
    ALTER TABLE Lots.Lot ADD CastDate DATE NULL;
GO

IF COL_LENGTH('Location.Location', 'DefaultStockLocationId') IS NULL
    ALTER TABLE Location.Location ADD DefaultStockLocationId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Location_DefaultStockLocation')
    ALTER TABLE Location.Location
        ADD CONSTRAINT FK_Location_DefaultStockLocation
        FOREIGN KEY (DefaultStockLocationId) REFERENCES Location.Location(Id);
GO

-- Guarded like 0058/0079: the top-of-file RETURN only exits its OWN batch.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0080_cutover_entry_route_and_cast_date')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0080_cutover_entry_route_and_cast_date',
            N'Lots.Lot.EntryRouteSequence + Lots.Lot.CastDate + Location.Location.DefaultStockLocationId (self-FK). All nullable, no backfill. Inventory cutover scan support.');
GO
PRINT 'Migration 0080 (cutover_entry_route_and_cast_date) applied.';
GO
