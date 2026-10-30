-- =============================================
-- Repeatable:  R__Oee_ufn_DowntimeEventMinutes.sql
-- Object:      Oee.ufn_DowntimeEventMinutes
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   THE duration of one downtime entry, in minutes (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.1 sec 6.1,
--   D17). One definition, used by Oee.ufn_ShiftAvailability and the dashboard's
--   downtime panels:
--     IsApproximate = 1 -> DurationMinutes (operator input; the stored
--                          StartedAt/EndedAt are a nominal window anchored at
--                          the shift start -- see DowntimeEvent_RecordApproximate)
--     otherwise         -> EndedAt - StartedAt; an entry with no EndedAt runs
--                          to @OpenEndUtc (the caller passes min(now, window end))
--   Never negative. An approximate entry with no DurationMinutes falls back to
--   its stored window.
--
--   Inline TVF: CROSS APPLY it per DowntimeEvent row.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_DowntimeEventMinutes
(
    @IsApproximate   BIT,
    @DurationMinutes INT,
    @StartedAt       DATETIME2(3),
    @EndedAt         DATETIME2(3),
    @OpenEndUtc      DATETIME2(3)
)
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(
               CASE
                   WHEN @IsApproximate = 1 AND @DurationMinutes IS NOT NULL
                       THEN CASE WHEN @DurationMinutes < 0 THEN 0 ELSE @DurationMinutes END
                   WHEN x.E IS NULL OR x.E <= @StartedAt
                       THEN 0
                   ELSE DATEDIFF_BIG(MILLISECOND, @StartedAt, x.E) / 60000.0
               END AS DECIMAL(12,4)) AS Minutes
    FROM (SELECT COALESCE(@EndedAt, @OpenEndUtc) AS E) x
);
GO
