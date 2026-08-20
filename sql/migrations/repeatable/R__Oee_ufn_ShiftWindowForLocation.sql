-- ============================================================
-- Repeatable:  R__Oee_ufn_ShiftWindowForLocation.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
-- Description: THE shift-window resolver. Given an equipment location, a shift
--              schedule and a calendar (business) date, returns the concrete
--              window that shift runs for THAT equipment on THAT day.
--
--              Resolution rule (Hunter, 2026-08-19):
--                if the equipment has an active override for the day -> use it;
--                otherwise fall back to the global Oee.ShiftSchedule window.
--
--              Inline TVF so callers can CROSS APPLY it per row (an availability
--              rollup over every press for a shift is one set-based query).
--              @LocationId may be NULL -> always the global window, which is how
--              a plant-wide caller asks the same question.
--
--              TIME BASIS -- LOCAL (Eastern) wall clock, matching
--              Oee.ShiftSchedule and Oee.Shift.ActualStart/ActualEnd (OI-38).
--              StartLocal/EndLocal are naive local DATETIME2(3). Callers that
--              must compare against a UTC column (Oee.DowntimeEvent.StartedAt)
--              convert at the boundary with
--                CAST(x AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))
--              -- AT TIME ZONE is DST-aware, so that conversion is correct even
--              though the wall-clock DURATION below is not (see below).
--
--              MIDNIGHT CROSSING: EndTime < StartTime => EndLocal lands on
--              BusinessDate + 1 day. A 22:00-06:00 shift on 2026-08-19 resolves
--              to 2026-08-19 22:00 -> 2026-08-20 06:00. Extending it to 08:00
--              keeps EndTime < StartTime and still lands on BusinessDate + 1.
--              Identical to the boundary math in Oee.Shift_Reconcile, so an
--              override window and a reconciled Oee.Shift row agree by
--              construction. EndTime = StartTime cannot occur
--              (CK_ShiftOverride_NonZeroWindow), so the CASE is total.
--
--              DST: DurationMinutes is WALL-CLOCK minutes, not elapsed minutes.
--              A window spanning the spring-forward instant is 60 minutes
--              shorter in reality than reported (fall-back: 60 longer). MPP's
--              exposure is the Sat 23:00 -> Sun 07:00 third shift on the two DST
--              Sundays. Inherited from the subsystem's local basis (OI-38) --
--              documented, not silently absorbed.
--
--              Read-only function: no OUTPUT params, no audit, no status row.
--
-- Parameters:
--   @LocationId      BIGINT NULL - equipment (downtime scope location). NULL =
--                                  global window, no override lookup.
--   @ShiftScheduleId BIGINT      - the shift being resolved.
--   @BusinessDate    DATE        - LOCAL calendar date the shift instance STARTS on.
--
-- Result set:
--   Exactly one row when the schedule exists and is active; zero rows otherwise.
--     LocationId, ShiftScheduleId, ScheduleName, BusinessDate,
--     StartTime, EndTime           - resolved TIME(0) (override's or schedule's)
--     StartLocal, EndLocal         - concrete local DATETIME2(3) window
--     DurationMinutes              - wall-clock minutes (see DST note)
--     IsOverridden                 - BIT; 1 when an override supplied the window
--     ShiftOverrideId              - the winning override's Id, or NULL
--     OverrideReason               - the winning override's Reason, or NULL
--
-- Dependencies:
--   Tables: Oee.ShiftSchedule, Oee.ShiftOverride
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftWindowForLocation
(
    @LocationId      BIGINT,
    @ShiftScheduleId BIGINT,
    @BusinessDate    DATE
)
RETURNS TABLE
AS
RETURN
(
    WITH Resolved AS (
        SELECT
            ss.Id           AS ShiftScheduleId,
            ss.Name         AS ScheduleName,
            w.StartTime,
            w.EndTime,
            w.IsOverridden,
            w.ShiftOverrideId,
            w.OverrideReason
        FROM Oee.ShiftSchedule ss
        CROSS APPLY (
            -- Rank 0 = the equipment's active override for the day (at most one,
            -- UX_ShiftOverride_Active); rank 1 = the global schedule fallback.
            -- TOP 1 + ORDER BY Rnk is the "override wins, else global" rule.
            SELECT TOP 1 c.StartTime, c.EndTime, c.IsOverridden,
                         c.ShiftOverrideId, c.OverrideReason
            FROM (
                SELECT ov.StartTime,
                       ov.EndTime,
                       CAST(1 AS BIT)        AS IsOverridden,
                       ov.Id                 AS ShiftOverrideId,
                       ov.Reason             AS OverrideReason,
                       0                     AS Rnk
                FROM Oee.ShiftOverride ov
                WHERE ov.LocationId      = @LocationId
                  AND ov.ShiftScheduleId = ss.Id
                  AND ov.BusinessDate    = @BusinessDate
                  AND ov.DeprecatedAt IS NULL
                UNION ALL
                SELECT ss.StartTime,
                       ss.EndTime,
                       CAST(0 AS BIT),
                       CAST(NULL AS BIGINT),
                       CAST(NULL AS NVARCHAR(500)),
                       1
            ) c
            ORDER BY c.Rnk
        ) w
        WHERE ss.Id = @ShiftScheduleId
          AND ss.DeprecatedAt IS NULL
    ),
    Bounded AS (
        SELECT
            r.ShiftScheduleId,
            r.ScheduleName,
            r.StartTime,
            r.EndTime,
            r.IsOverridden,
            r.ShiftOverrideId,
            r.OverrideReason,
            DATEADD(SECOND, DATEDIFF(SECOND, 0, r.StartTime),
                    CAST(@BusinessDate AS DATETIME2(3))) AS StartLocal,
            CASE WHEN r.EndTime > r.StartTime
                 THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, r.EndTime),
                              CAST(@BusinessDate AS DATETIME2(3)))
                 ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, r.EndTime),
                              CAST(DATEADD(DAY, 1, @BusinessDate) AS DATETIME2(3)))
            END AS EndLocal
        FROM Resolved r
    )
    SELECT
        @LocationId       AS LocationId,
        b.ShiftScheduleId,
        b.ScheduleName,
        @BusinessDate     AS BusinessDate,
        b.StartTime,
        b.EndTime,
        b.StartLocal,
        b.EndLocal,
        DATEDIFF(MINUTE, b.StartLocal, b.EndLocal) AS DurationMinutes,
        b.IsOverridden,
        b.ShiftOverrideId,
        b.OverrideReason
    FROM Bounded b
);
GO
