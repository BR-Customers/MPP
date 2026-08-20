-- =============================================
-- Procedure:   Oee.ShiftOverride_List
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Shift overrides for the config list screen, newest business date first.
--   Every filter is optional; no args = every active override.
--
--   Each row carries BOTH the schedule's baseline window and the override's
--   window, plus the wall-clock minute delta, so the screen can render
--   "First 06:00-14:30 -> 06:00-16:30 (+120 min)" without a second query and
--   without re-deriving the rule client-side.
--
--   Read proc: ONE result set; empty = nothing matches. No OUTPUT params, no
--   audit (FDS-11-011).
--
--   Times: StartTime / EndTime are LOCAL (Eastern) wall clock TIME(0) values --
--   no timezone conversion applies. The two windows are expanded with the SAME
--   midnight-crossing rule as Oee.ufn_ShiftWindowForLocation (EndTime <
--   StartTime => end lands on BusinessDate + 1), inline rather than through the
--   resolver: this proc lists the override ROWS, including deprecated ones, and
--   the resolver deliberately ignores deprecated rows -- routing through it
--   would report DeltaMinutes = 0 for every deprecated override. DeltaMinutes
--   is WALL-CLOCK minutes and so is off by 60 across a DST boundary (see the
--   resolver's header).
--
-- Parameters (input):
--   @LocationId        BIGINT = NULL - Only this equipment.
--   @FromDate          DATE   = NULL - BusinessDate >= this.
--   @ToDate            DATE   = NULL - BusinessDate <= this.
--   @IncludeDeprecated BIT    = 0    - 1 also returns soft-deleted overrides.
--
-- Result set:
--   Id, LocationId, LocationCode, LocationName, ShiftScheduleId, ScheduleName,
--   ScheduleStartTime, ScheduleEndTime, BusinessDate, StartTime, EndTime,
--   StartLocal, EndLocal, DurationMinutes, DeltaMinutes, Reason, IsDeprecated,
--   CreatedByInitials
--
-- Dependencies:
--   Tables: Oee.ShiftOverride, Oee.ShiftSchedule, Location.Location, Location.AppUser
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_List
    @LocationId        BIGINT = NULL,
    @FromDate          DATE   = NULL,
    @ToDate            DATE   = NULL,
    @IncludeDeprecated BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ov.Id,
        ov.LocationId,
        loc.Code                AS LocationCode,
        loc.Name                AS LocationName,
        ov.ShiftScheduleId,
        ss.Name                 AS ScheduleName,
        ss.StartTime            AS ScheduleStartTime,
        ss.EndTime              AS ScheduleEndTime,
        ov.BusinessDate,
        ov.StartTime,
        ov.EndTime,
        w.StartLocal,
        w.EndLocal,
        DATEDIFF(MINUTE, w.StartLocal, w.EndLocal) AS DurationMinutes,
        DATEDIFF(MINUTE, w.StartLocal, w.EndLocal)
            - DATEDIFF(MINUTE, w.BaseStartLocal, w.BaseEndLocal) AS DeltaMinutes,
        ov.Reason,
        CAST(CASE WHEN ov.DeprecatedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsDeprecated,
        cu.Initials             AS CreatedByInitials
    FROM Oee.ShiftOverride ov
    INNER JOIN Location.Location loc ON loc.Id = ov.LocationId
    INNER JOIN Oee.ShiftSchedule ss  ON ss.Id  = ov.ShiftScheduleId
    LEFT  JOIN Location.AppUser  cu  ON cu.Id  = ov.CreatedByUserId
    -- Both windows expanded with the resolver's midnight-crossing rule.
    CROSS APPLY (
        SELECT
            DATEADD(SECOND, DATEDIFF(SECOND, 0, ov.StartTime),
                    CAST(ov.BusinessDate AS DATETIME2(3))) AS StartLocal,
            CASE WHEN ov.EndTime > ov.StartTime
                 THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ov.EndTime),
                              CAST(ov.BusinessDate AS DATETIME2(3)))
                 ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ov.EndTime),
                              CAST(DATEADD(DAY, 1, ov.BusinessDate) AS DATETIME2(3)))
            END AS EndLocal,
            DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.StartTime),
                    CAST(ov.BusinessDate AS DATETIME2(3))) AS BaseStartLocal,
            CASE WHEN ss.EndTime > ss.StartTime
                 THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime),
                              CAST(ov.BusinessDate AS DATETIME2(3)))
                 ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime),
                              CAST(DATEADD(DAY, 1, ov.BusinessDate) AS DATETIME2(3)))
            END AS BaseEndLocal
    ) w
    WHERE (@LocationId IS NULL OR ov.LocationId   = @LocationId)
      AND (@FromDate   IS NULL OR ov.BusinessDate >= @FromDate)
      AND (@ToDate     IS NULL OR ov.BusinessDate <= @ToDate)
      AND (@IncludeDeprecated = 1 OR ov.DeprecatedAt IS NULL)
    ORDER BY ov.BusinessDate DESC, loc.Code, ss.StartTime, ov.Id DESC;
END
GO
