-- =============================================
-- Procedure:   Oee.Shift_GetAvailability
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     4.0
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
--   v2.0 (OEE-enabled locations spec, 2026-09-16). FOUR DELIBERATE CHOICES:
--
--   1. PLANNED time comes from the SCHEDULE (+ override), never from
--      Oee.Shift.ActualStart/ActualEnd. The runtime row records when the
--      boundary engine actually noticed the shift; a gateway outage that
--      backfills late must not shrink the planned denominator.
--
--   2. DOWNTIME is the SUM of entered DURATIONS, attributed by de.ShiftId
--      (v4.0, OEE dashboard spec v0.3.1 D17 -- a behaviour change). MPP's
--      downtime is mostly a duration entered at the end of the shift and
--      stored at the shift start (DowntimeEvent_RecordApproximate), so v2-v3's
--      clock-overlap merge counted two such entries once. An entry counts
--      against the shift it was entered for, wherever its clock time falls;
--      that also retires v2's double-count where an extension overlapped the
--      next shift's window. Duration rule: Oee.ufn_DowntimeEventMinutes.
--      Unplanned is capped at the base.

--   3. PLANNED DOWNTIME SHRINKS THE BASE (v2.0 -- a behaviour change).
--      Availability was (scheduled - ALL downtime) / scheduled, so a 30-minute
--      lunch counted against the operator like a breakdown. It is now
--      (base - unplanned) / base with base = scheduled - planned, which is
--      standard OEE and what MPP means by "planned". Expect higher numbers
--      wherever breaks are logged. "Planned" = DowntimeReasonCode.IsExcused.
--
--   4. A UNIT INHERITS ITS FLAGGED ANCESTORS' DOWNTIME, AND A UNIT WITH
--      FLAGGED UNITS BENEATH IT REPORTS THEIR MEAN. This is what lets one
--      line carry per-station units: a line-wide stop hits every station, a
--      side-A jam hits only side A, and the line's figure is the average of
--      its stations -- the only number that matches the parts not made. No
--      capacity weighting: WIP buffers decouple the stations, so a fixed
--      weight would be wrong minute to minute (spec D6). Entries are summed,
--      not merged: an entry entered twice counts twice (v4.0).
--
--   ROUNDING. Minute columns are rounded once to INT; Availability is computed
--   from the unrounded minutes and rounded once to DECIMAL(5,4). A real-time
--   entry with no EndedAt runs to min(now, window end).

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
--   Availability (DECIMAL(5,4), NULL when BaseMinutes = 0),
--   DowntimeEventCount, IsOverridden, ShiftOverrideId, OverrideReason,
--   PlannedDowntimeMinutes, UnplannedDowntimeMinutes, BaseMinutes,
--   IsRollup, ParentLocationId                       (v2.0, appended)
--   On an IsRollup = 1 row the minute columns describe the unit's OWN events
--   only and Availability is the mean of its children -- never sum them.
--
-- Dependencies:
--   Tables: Oee.Shift, Oee.DowntimeEvent, Oee.DowntimeReasonCode
--   Funcs:  Oee.ufn_ResolveOeeEquipment, Oee.ufn_OeeAncestors,
--           Oee.ufn_ShiftWindowForLocation
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1 / 6.2).
--   2026-09-17 - 2.0 - Base-shrinking availability + ancestor inheritance + mean roll-up.
--   2026-09-17 - 2.0.1 - Review fixes: no null-aggregate warning, honest minute-grid note, single rounding.
--   2026-10-29 - 3.0 - Body moved to Oee.ufn_ShiftAvailability (OEE dashboard spec sec 6.1); this proc
--                      is now a filtered, ordered SELECT from it. Behaviour and columns unchanged.
--   2026-10-30 - 4.0 - Summed entered durations attributed by ShiftId (Oee.ufn_ShiftAvailability v2.0,
--                      spec v0.3.1 D17); unplanned capped at the base. Columns unchanged.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Shift_GetAvailability
    @ShiftId    BIGINT,
    @LocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- v3.0: the calculation lives in Oee.ufn_ShiftAvailability (same rules,
    -- same columns). An unknown shift returns no rows there, so the empty
    -- result set still means "shift not found".
    SELECT
        a.ShiftId, a.ShiftScheduleId, a.ScheduleName, a.BusinessDate,
        a.LocationId, a.LocationCode, a.LocationName,
        a.StartLocal, a.EndLocal, a.PlannedMinutes,
        a.DowntimeMinutes, a.UnexcusedDowntimeMinutes, a.RunMinutes,
        a.Availability, a.DowntimeEventCount, a.IsOverridden,
        a.ShiftOverrideId, a.OverrideReason,
        a.PlannedDowntimeMinutes, a.UnplannedDowntimeMinutes, a.BaseMinutes,
        a.IsRollup, a.ParentLocationId
    FROM Oee.ufn_ShiftAvailability(@ShiftId) a
    WHERE @LocationId IS NULL OR a.LocationId = @LocationId
    ORDER BY a.SortParentName, a.SortOrder, a.LocationName;
END
GO
