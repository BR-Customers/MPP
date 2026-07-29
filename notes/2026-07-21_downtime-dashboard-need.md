# Downtime / OEE dashboard - need noted 2026-07-21

Raised by Jacques while building the Shift Schedules config screen.

**Context:** The downtime subsystem records everything (Oee.DowntimeEvent open/close
intervals, ShiftId linkage, IsExcused, source Operator/PLC, break durations via
EndOfShiftEntry_Submit) but there is NO rollup/dashboard surface. Today only
Oee.DowntimeEvent_GetOpenSummary (plant-wide open counts, triage) and
Oee.DowntimeEvent_GetOpenByLocation exist.

**Wanted (future spec):**
- Open downtime by cell/line (live).
- Downtime Pareto by reason code and by reason type, over a shift/day/date-range.
- Availability % once a shift-availability rollup exists (downtime minutes vs shift
  minutes per Oee.Shift) - no proc computes A/P/Q today.

**Not started.** Separate brainstorm -> spec -> plan when scheduled. Related: the
shift-availability rollup gap and the absence of any OEE metric calculation.
