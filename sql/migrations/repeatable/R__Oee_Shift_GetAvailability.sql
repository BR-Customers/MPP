-- =============================================
-- Procedure:   Oee.Shift_GetAvailability
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Per-equipment availability for one runtime shift instance: planned minutes
--   (override-aware), downtime minutes, run minutes, availability ratio.
--
--   This is the proc specified but never built in the Phase 8 plan
--   ("ShiftAvailabilityTile ... add Oee.Shift_GetAvailability read proc + NQ",
--   2026-06-16-arc2-phase8-downtime-shift.md), and it is what makes a
--   per-equipment shift override actually "affect OEE": PlannedMinutes comes
--   from Oee.ufn_ShiftWindowForLocation, so an extended press reports a longer
--   denominator than its neighbours on the same shift.
--
--   TWO DELIBERATE CHOICES, both load-bearing:
--
--   1. PLANNED time comes from the SCHEDULE (+ override), never from
--      Oee.Shift.ActualStart/ActualEnd. The runtime row records when the
--      boundary engine actually noticed the shift; a gateway outage that
--      backfills late must not shrink the planned denominator.
--
--   2. DOWNTIME is summed by TIME OVERLAP with the resolved window, NOT by
--      de.ShiftId. This is the whole point: when equipment is extended past the
--      global boundary, the downtime it incurs in the extension carries the
--      NEXT shift's ShiftId (Oee.DowntimeEvent_Start stamps whichever shift is
--      open plant-wide). Bucketing by ShiftId would grow the denominator while
--      ignoring the numerator and silently inflate availability. Overlap is
--      independent of how events were bucketed.
--      CONSEQUENCE (needs a product decision -- see the report): where an
--      extension overlaps the next shift's window, those minutes count toward
--      BOTH shifts' availability for that equipment. Authoring a matching
--      shortening override on the next shift removes the overlap.
--
--   TIME BASIS. Oee.Shift.ActualStart, Oee.ShiftSchedule.StartTime and
--   Oee.ShiftOverride.StartTime are all LOCAL (Eastern) wall clock (OI-38), so
--   BusinessDate is taken from ActualStart with NO conversion -- converting it
--   is the live bug this proc deliberately avoids. Oee.DowntimeEvent.StartedAt
--   IS stored UTC, so the local window is converted to UTC at the comparison
--   boundary with AT TIME ZONE, which is DST-aware.
--   PlannedMinutes remains WALL-CLOCK minutes: a window spanning a DST
--   transition is reported 60 minutes longer/shorter than it really ran, so
--   availability is off by that ratio on the two DST Sundays. Inherited from
--   the subsystem's local basis (OI-38); see Oee.ufn_ShiftWindowForLocation.
--
--   Read proc: ONE result set; empty = shift not found. No OUTPUT params, no
--   audit (FDS-11-011).
--
-- Parameters (input):
--   @ShiftId    BIGINT        - Runtime Oee.Shift instance. Required.
--   @LocationId BIGINT = NULL - One piece of equipment; NULL = every piece,
--                               one row each.
--
-- Result set (one row per equipment):
--   ShiftId, ShiftScheduleId, ScheduleName, BusinessDate,
--   LocationId, LocationCode, LocationName,
--   StartLocal, EndLocal, PlannedMinutes,
--   DowntimeMinutes, UnexcusedDowntimeMinutes, RunMinutes,
--   Availability (DECIMAL(5,4), NULL when PlannedMinutes = 0),
--   DowntimeEventCount, IsOverridden, ShiftOverrideId, OverrideReason
--
-- Dependencies:
--   Tables: Oee.Shift, Oee.DowntimeEvent, Oee.DowntimeReasonCode
--   Funcs:  Oee.ufn_ResolveOeeEquipment, Oee.ufn_ShiftWindowForLocation
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1 / 6.2).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Shift_GetAvailability
    @ShiftId    BIGINT,
    @LocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchedId      BIGINT;
    DECLARE @BusinessDate DATE;

    -- ActualStart is LOCAL (OI-38) -- cast straight to DATE, no conversion.
    SELECT @SchedId      = s.ShiftScheduleId,
           @BusinessDate = CAST(s.ActualStart AS DATE)
    FROM Oee.Shift s
    WHERE s.Id = @ShiftId;

    IF @SchedId IS NULL
        RETURN;   -- empty result set = shift not found (no invented 404)

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    SELECT
        @ShiftId            AS ShiftId,
        w.ShiftScheduleId,
        w.ScheduleName,
        w.BusinessDate,
        e.LocationId,
        e.Code              AS LocationCode,
        e.Name              AS LocationName,
        w.StartLocal,
        w.EndLocal,
        w.DurationMinutes   AS PlannedMinutes,
        dt.DowntimeMinutes,
        dt.UnexcusedDowntimeMinutes,
        CASE WHEN w.DurationMinutes - dt.DowntimeMinutes < 0
             THEN 0 ELSE w.DurationMinutes - dt.DowntimeMinutes END AS RunMinutes,
        CASE WHEN w.DurationMinutes = 0 THEN NULL
             ELSE CAST(
                 CASE WHEN w.DurationMinutes - dt.DowntimeMinutes < 0
                      THEN 0 ELSE w.DurationMinutes - dt.DowntimeMinutes END
                 * 1.0 / w.DurationMinutes AS DECIMAL(5,4)) END AS Availability,
        dt.DowntimeEventCount,
        w.IsOverridden,
        w.ShiftOverrideId,
        w.OverrideReason
    FROM Oee.ufn_ResolveOeeEquipment() e
    CROSS APPLY Oee.ufn_ShiftWindowForLocation(e.LocationId, @SchedId, @BusinessDate) w
    -- Local window -> UTC for comparison against Oee.DowntimeEvent.StartedAt.
    -- AT TIME ZONE is DST-aware, so this conversion is exact.
    CROSS APPLY (
        SELECT CAST(w.StartLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc,
               CAST(w.EndLocal   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS EndUtc
    ) u
    -- Downtime clipped to the window (see choice 2 in the header). An open
    -- event is measured to now; a future window contributes nothing.
    CROSS APPLY (
        SELECT
            COALESCE(SUM(ov.Mins), 0)                                          AS DowntimeMinutes,
            COALESCE(SUM(CASE WHEN ov.Excused = 0 THEN ov.Mins ELSE 0 END), 0) AS UnexcusedDowntimeMinutes,
            COUNT(*)                                                           AS DowntimeEventCount
        FROM Oee.DowntimeEvent de
        LEFT JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
        CROSS APPLY (
            SELECT DATEDIFF(
                       MINUTE,
                       CASE WHEN de.StartedAt > u.StartUtc THEN de.StartedAt ELSE u.StartUtc END,
                       CASE WHEN COALESCE(de.EndedAt, @Now) < u.EndUtc
                            THEN COALESCE(de.EndedAt, @Now) ELSE u.EndUtc END
                   ) AS Mins,
                   COALESCE(rc.IsExcused, CAST(0 AS BIT)) AS Excused
        ) ov
        WHERE de.LocationId = e.LocationId
          AND de.VoidedAt IS NULL
          AND de.StartedAt < u.EndUtc
          AND COALESCE(de.EndedAt, @Now) > u.StartUtc
    ) dt
    WHERE @LocationId IS NULL OR e.LocationId = @LocationId
    ORDER BY e.ParentName, e.SortOrder, e.Name;
END
GO
