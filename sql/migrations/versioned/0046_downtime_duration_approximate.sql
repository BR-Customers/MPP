-- ============================================================
-- Migration:   0046_downtime_duration_approximate.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: Downtime duration model + approximate (duration-only) capture.
--                1. Oee.DowntimeEvent += IsApproximate BIT (default 0).
--                2. Oee.DowntimeEvent += DurationMinutes INT NULL -- materialized
--                   duration, ALWAYS stored on close/record (exact: DATEDIFF of
--                   the times; approximate: operator-entered). NULL only while an
--                   exact event is still open.
--                3. Backfill DurationMinutes for existing CLOSED events.
--              Rationale: end-of-shift reconstruction ("down ~45 min, don't recall
--              the exact window") is the common manual-entry case. Approximate
--              events store a NOMINAL shift-anchored window (so the one-open
--              filtered-unique index and shift OEE bucketing keep working) with
--              IsApproximate=1 signalling the window is not precise -- only
--              DurationMinutes + ShiftId are authoritative. OEE shift availability
--              sums DurationMinutes by ShiftId, so nominal placement never skews it.
--              Idempotent, GO-separated (ADD then backfill needs the column visible).
--              The RecordApproximate proc + duration stamping in Record/End/Update
--              live in their repeatable R__ files.
-- ============================================================

-- ---- 1. IsApproximate ----
IF COL_LENGTH(N'Oee.DowntimeEvent', N'IsApproximate') IS NULL
    ALTER TABLE Oee.DowntimeEvent
        ADD IsApproximate BIT NOT NULL CONSTRAINT DF_DowntimeEvent_IsApproximate DEFAULT 0;
GO

-- ---- 2. DurationMinutes (materialized) ----
IF COL_LENGTH(N'Oee.DowntimeEvent', N'DurationMinutes') IS NULL
    ALTER TABLE Oee.DowntimeEvent ADD DurationMinutes INT NULL;
GO

-- ---- 3. Backfill closed events (batch break so the new column is visible) ----
UPDATE Oee.DowntimeEvent
   SET DurationMinutes = DATEDIFF(MINUTE, StartedAt, EndedAt)
 WHERE EndedAt IS NOT NULL
   AND DurationMinutes IS NULL;
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0046_downtime_duration_approximate')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0046_downtime_duration_approximate',
        N'Downtime duration model: Oee.DowntimeEvent += IsApproximate + materialized DurationMinutes; backfill closed events. Enables duration-only (approximate) end-of-shift capture.');
GO

PRINT 'Migration 0046 (downtime duration + approximate capture) applied.';
GO
