-- ============================================================
-- Repeatable:  R__Oee_ufn_ShiftWindowForShift.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-03
-- Version:     1.0
-- Description: The window ONE RECORDED SHIFT ran for one piece of equipment.
--              Sibling of Oee.ufn_ShiftWindowForLocation, which answers the
--              forward-looking question "what is this schedule's window on
--              that day" from the schedule as it is NOW. This function answers
--              the historical one, so a schedule change is a line in the sand:
--
--                1. the equipment's active override for the shift's day wins;
--                2. a CLOSED shift otherwise runs Oee.Shift.ActualStart ->
--                   ActualEnd -- the boundaries Oee.Shift_Reconcile wrote when
--                   it happened. Editing the schedule's times later does not
--                   move it, and deprecating the schedule does not hide it;
--                3. the OPEN shift runs ActualStart -> the schedule's current
--                   end (it has not ended yet, so today's schedule is the only
--                   answer there is).
--
--              No DeprecatedAt filter on Oee.ShiftSchedule: the shift row exists,
--              so its window exists.
--
--              TIME BASIS -- LOCAL (Eastern) wall clock, as
--              Oee.ufn_ShiftWindowForLocation (OI-38); same DST note applies.
--
--              Inline TVF; same columns as Oee.ufn_ShiftWindowForLocation so a
--              caller can swap one for the other.
--
-- Parameters:
--   @LocationId BIGINT NULL - equipment; NULL = no override lookup.
--   @ShiftId    BIGINT      - the Oee.Shift row.
--
-- Result set: exactly one row when the shift exists; zero otherwise.
--   LocationId, ShiftScheduleId, ScheduleName, BusinessDate, StartTime, EndTime,
--   StartLocal, EndLocal, DurationMinutes, IsOverridden, ShiftOverrideId,
--   OverrideReason
--
-- Dependencies: Oee.Shift, Oee.ShiftSchedule, Oee.ShiftOverride
--
-- Change Log:
--   2026-11-03 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftWindowForShift
(
    @LocationId BIGINT,
    @ShiftId    BIGINT
)
RETURNS TABLE
AS
RETURN
(
    WITH Sh AS (
        SELECT s.ShiftScheduleId,
               ss.Name                      AS ScheduleName,
               CAST(s.ActualStart AS DATE)  AS BusinessDate,
               s.ActualStart,
               -- open shift: the schedule's current end on the shift's day
               ISNULL(s.ActualEnd,
                      CASE WHEN ss.EndTime > ss.StartTime
                           THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(CAST(s.ActualStart AS DATE) AS DATETIME2(3)))
                           ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(DATEADD(DAY, 1, CAST(s.ActualStart AS DATE)) AS DATETIME2(3)))
                      END)                  AS ActualEnd
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.Id = @ShiftId
    ),
    Resolved AS (
        SELECT sh.ShiftScheduleId, sh.ScheduleName, sh.BusinessDate,
               CASE WHEN ov.Id IS NULL THEN sh.ActualStart
                    ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ov.StartTime), CAST(sh.BusinessDate AS DATETIME2(3))) END AS StartLocal,
               CASE WHEN ov.Id IS NULL THEN sh.ActualEnd
                    WHEN ov.EndTime > ov.StartTime
                    THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ov.EndTime), CAST(sh.BusinessDate AS DATETIME2(3)))
                    ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ov.EndTime), CAST(DATEADD(DAY, 1, sh.BusinessDate) AS DATETIME2(3))) END AS EndLocal,
               CAST(CASE WHEN ov.Id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsOverridden,
               ov.Id     AS ShiftOverrideId,
               ov.Reason AS OverrideReason
        FROM Sh sh
        OUTER APPLY (SELECT TOP 1 o.Id, o.StartTime, o.EndTime, o.Reason
                     FROM Oee.ShiftOverride o
                     WHERE o.LocationId      = @LocationId
                       AND o.ShiftScheduleId = sh.ShiftScheduleId
                       AND o.BusinessDate    = sh.BusinessDate
                       AND o.DeprecatedAt IS NULL) ov
    )
    SELECT @LocationId                                AS LocationId,
           r.ShiftScheduleId,
           r.ScheduleName,
           r.BusinessDate,
           CAST(r.StartLocal AS TIME(0))              AS StartTime,
           CAST(r.EndLocal   AS TIME(0))              AS EndTime,
           r.StartLocal,
           r.EndLocal,
           DATEDIFF(MINUTE, r.StartLocal, r.EndLocal) AS DurationMinutes,
           r.IsOverridden,
           r.ShiftOverrideId,
           r.OverrideReason
    FROM Resolved r
);
GO
