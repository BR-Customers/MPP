-- ============================================================
-- Migration:   0077_downtime_approximate_utc_repair.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-11
-- Description: Repairs duration-only ("approximate") downtime events whose
--              nominal window was stored 4 h early (EDT; 5 h in EST).
--
--              Oee.DowntimeEvent_RecordApproximate v1.0 anchored StartedAt on
--              Oee.Shift.ActualStart -- which is Eastern WALL-CLOCK -- and
--              wrote it into the UTC StartedAt column unconverted. Found on
--              prod 2026-09-11: every approximate event read 03:00 for a
--              07:00 shift, 11:00 for a 15:00 shift. v1.1 converts.
--
--              WHICH ROWS. Exactly the ones the bug produced: IsApproximate = 1
--              and StartedAt equal to its own shift's ActualStart. A correctly
--              converted value can never equal the Eastern one (the offset is
--              never zero), so this is also a no-op on any re-run -- every
--              batch is safe even though the top guard only exits batch 1.
--              Rows from the no-shift fallback (now - duration, already UTC)
--              do not match and are untouched.
--
--              WHAT CHANGES. StartedAt := ActualStart converted ET -> UTC;
--              EndedAt := StartedAt + DurationMinutes. ShiftId, DurationMinutes
--              and everything else are unchanged -- they were always correct.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0077_downtime_approximate_utc_repair')
BEGIN
    PRINT 'Migration 0077 already applied -- skipping.';
    RETURN;
END
GO

DECLARE @Fixed INT;

UPDATE de
SET de.StartedAt = x.StartUtc,
    de.EndedAt   = DATEADD(MINUTE, de.DurationMinutes, x.StartUtc)
FROM Oee.DowntimeEvent de
INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
CROSS APPLY (SELECT CAST(sh.ActualStart AT TIME ZONE 'Eastern Standard Time'
                                        AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc) x
WHERE de.IsApproximate = 1
  AND de.DurationMinutes IS NOT NULL
  AND de.StartedAt = sh.ActualStart;

SET @Fixed = @@ROWCOUNT;
PRINT '0077: ' + CAST(@Fixed AS NVARCHAR(20)) + ' approximate downtime event(s) moved from Eastern wall-clock to UTC.';
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0077_downtime_approximate_utc_repair')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0077_downtime_approximate_utc_repair',
        N'Approximate downtime events stored with StartedAt = the shift''s Eastern wall-clock ActualStart (RecordApproximate v1.0) moved to UTC; EndedAt = StartedAt + DurationMinutes. Matches only rows the bug produced; re-run is a no-op.'
    );
GO

PRINT 'Migration 0077 completed: approximate downtime UTC repair.';
GO
