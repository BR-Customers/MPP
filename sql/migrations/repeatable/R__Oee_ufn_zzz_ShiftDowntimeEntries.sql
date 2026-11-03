-- =============================================
-- Repeatable:  R__Oee_ufn_zzz_ShiftDowntimeEntries.sql
-- Object:      Oee.ufn_ShiftDowntimeEntries
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.1
--
-- Description:
--   One shift's ENTERED downtime, one row per entry, with its duration and
--   where it is booked (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 6.1,
--   6.7). The one definition of "the shift's entries" behind the stored
--   downtime minutes (Oee.ufn_ShiftSummaryRows), the reason Pareto
--   (Dashboard_GetDowntimeByReason) and the entry list
--   (Dashboard_GetDowntimeEntries), so the three always agree.
--     entries   DowntimeEvent.ShiftId = the shift, not voided
--     Minutes   Oee.ufn_DowntimeEventMinutes; an open entry runs to
--               min(now, the location's window end) -- the window the
--               shift ran (Oee.ufn_ShiftWindowForShift), not today's schedule
--     placement Oee.ufn_AreaFamily (the top unit, or the area)
--     IsPlanned the reason IsExcused; IsNoReason no reason at all (unplanned)
--
--   Inline TVF. FILE NAME IS ORDER-SENSITIVE -- 'zzz_' sorts after
--   R__Oee_ufn_zz_AreaFamily, which it calls (ufn_ShiftWindowForShift and
--   ufn_DowntimeEventMinutes already sort earlier).
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
--   2026-11-03 - 1.1 - Window from Oee.ufn_ShiftWindowForShift (schedule edits do not
--                      move a closed shift's window).
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftDowntimeEntries (@ShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT de.Id                     AS DowntimeEventId,
           de.LocationId,
           af.PlacementLocationId,
           af.PlacementIsArea,
           af.AreaFamily,
           de.DowntimeReasonCodeId,
           m.Minutes,
           CAST(ISNULL(rc.IsExcused, 0) AS BIT)                                       AS IsPlanned,
           CAST(CASE WHEN de.DowntimeReasonCodeId IS NULL THEN 1 ELSE 0 END AS BIT)    AS IsNoReason,
           de.IsApproximate,
           de.StartedAt,
           de.AppUserId
    FROM Oee.Shift s
    INNER JOIN Oee.DowntimeEvent de ON de.ShiftId = s.Id AND de.VoidedAt IS NULL
    LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
    CROSS APPLY Oee.ufn_AreaFamily(de.LocationId) af
    OUTER APPLY (SELECT TOP 1 w.EndLocal
                 FROM Oee.ufn_ShiftWindowForShift(de.LocationId, s.Id) w) win
    CROSS APPLY (SELECT CASE WHEN win.EndLocal IS NULL THEN SYSUTCDATETIME()
                             ELSE CAST(win.EndLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END AS WinEndUtc) we
    CROSS APPLY Oee.ufn_DowntimeEventMinutes(de.IsApproximate, de.DurationMinutes, de.StartedAt, de.EndedAt,
        CASE WHEN we.WinEndUtc < SYSUTCDATETIME() THEN we.WinEndUtc ELSE SYSUTCDATETIME() END) m
    WHERE s.Id = @ShiftId
);
GO
