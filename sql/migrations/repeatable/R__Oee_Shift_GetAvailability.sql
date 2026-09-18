-- =============================================
-- Procedure:   Oee.Shift_GetAvailability
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     2.0.1
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
--   2. DOWNTIME is matched by TIME OVERLAP with the resolved window, NOT by
--      de.ShiftId -- when equipment is extended past the global boundary, the
--      downtime it incurs in the extension carries the NEXT shift's ShiftId.
--      CONSEQUENCE (needs a product decision -- see the report): where an
--      extension overlaps the next shift's window, those minutes count toward
--      BOTH shifts' availability for that equipment.
--
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
--      weight would be wrong minute to minute (spec D6). Overlapping events
--      are merged by clock so one stretch of downtime is counted once, and a
--      minute covered by anything planned counts as planned.
--
--   MINUTE GRID. Coverage is measured at each minute's midpoint. That is
--   exact for minute-aligned events (such as the tests use); a live event
--   is second-precision (Oee.DowntimeEvent_Start / _End stamp
--   SYSUTCDATETIME(), and _RecordApproximate stamps SYSUTCDATETIME() minus
--   N minutes), so a live event carries an error of at most about one
--   minute per event edge, unbiased -- comparable to the old
--   DATEDIFF(MINUTE, ...) rounding. A unit's figure can therefore differ
--   from v1.0 by about a minute's worth even with no planned events.
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
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Shift_GetAvailability
    @ShiftId    BIGINT,
    @LocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ActualStart is LOCAL (OI-38) -- cast straight to DATE, no conversion.
    DECLARE @SchedId      BIGINT;
    DECLARE @BusinessDate DATE;
    SELECT @SchedId      = s.ShiftScheduleId,
           @BusinessDate = CAST(s.ActualStart AS DATE)
    FROM Oee.Shift s
    WHERE s.Id = @ShiftId;

    IF @SchedId IS NULL
        RETURN;   -- empty result set = shift not found (no invented 404)

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    -- ================================================================
    -- 1. Every OEE unit, its window, and its nearest flagged parent
    -- ================================================================
    CREATE TABLE #Unit (
        LocationId               BIGINT        NOT NULL PRIMARY KEY,
        Code                     NVARCHAR(50)  NULL,
        Name                     NVARCHAR(200) NULL,
        ParentName               NVARCHAR(200) NULL,
        SortOrder                INT           NULL,
        FlaggedParentId          BIGINT        NULL,
        IsRollup                 BIT           NOT NULL DEFAULT 0,
        ShiftScheduleId          BIGINT        NULL,
        ScheduleName             NVARCHAR(100) NULL,
        BusinessDate             DATE          NULL,
        StartLocal               DATETIME2(3)  NULL,
        EndLocal                 DATETIME2(3)  NULL,
        PlannedMinutes           INT           NULL,
        StartUtc                 DATETIME2(3)  NULL,
        EndUtc                   DATETIME2(3)  NULL,
        IsOverridden             BIT           NULL,
        ShiftOverrideId          BIGINT        NULL,
        OverrideReason           NVARCHAR(500) NULL,
        PlannedDowntimeMinutes   INT           NOT NULL DEFAULT 0,
        UnplannedDowntimeMinutes INT           NOT NULL DEFAULT 0,
        DowntimeEventCount       INT           NOT NULL DEFAULT 0,
        AvailabilityRaw          DECIMAL(19,10) NULL,
        Done                     BIT           NOT NULL DEFAULT 0
    );

    INSERT INTO #Unit (LocationId, Code, Name, ParentName, SortOrder, FlaggedParentId,
                       ShiftScheduleId, ScheduleName, BusinessDate, StartLocal, EndLocal,
                       PlannedMinutes, StartUtc, EndUtc, IsOverridden, ShiftOverrideId, OverrideReason)
    SELECT e.LocationId, e.Code, e.Name, e.ParentName, e.SortOrder,
           (SELECT TOP 1 a.AncestorLocationId
            FROM Oee.ufn_OeeAncestors(e.LocationId) a
            ORDER BY a.Distance),
           w.ShiftScheduleId, w.ScheduleName, w.BusinessDate, w.StartLocal, w.EndLocal,
           w.DurationMinutes,
           -- Local window -> UTC for comparison against Oee.DowntimeEvent.StartedAt.
           -- AT TIME ZONE is DST-aware, so this conversion is exact.
           CAST(w.StartLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
           CAST(w.EndLocal   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
           w.IsOverridden, w.ShiftOverrideId, w.OverrideReason
    FROM Oee.ufn_ResolveOeeEquipment() e
    CROSS APPLY Oee.ufn_ShiftWindowForLocation(e.LocationId, @SchedId, @BusinessDate) w;

    -- A unit with a flagged unit beneath it reports the MEAN of those units.
    UPDATE u
       SET IsRollup = 1
    FROM #Unit u
    WHERE EXISTS (SELECT 1 FROM #Unit c WHERE c.FlaggedParentId = u.LocationId);

    -- ================================================================
    -- 2. Which locations' downtime each unit counts
    --    Itself always; for a LEAF also every flagged ancestor -- "if the line
    --    is down, all stations are impacted" (spec D5). A roll-up counts only
    --    its own events: its children already carry them, and adding them to
    --    the mean's input would double-count.
    -- ================================================================
    CREATE TABLE #Src (
        LocationId       BIGINT NOT NULL,
        SourceLocationId BIGINT NOT NULL,
        PRIMARY KEY (LocationId, SourceLocationId)
    );

    INSERT INTO #Src (LocationId, SourceLocationId)
    SELECT u.LocationId, u.LocationId FROM #Unit u;

    INSERT INTO #Src (LocationId, SourceLocationId)
    SELECT u.LocationId, a.AncestorLocationId
    FROM #Unit u
    CROSS APPLY Oee.ufn_OeeAncestors(u.LocationId) a
    WHERE u.IsRollup = 0
      AND a.AncestorLocationId <> u.LocationId;

    -- ================================================================
    -- 3. Downtime intervals, clipped to each unit's own window
    -- ================================================================
    CREATE TABLE #Iv (
        LocationId BIGINT       NOT NULL,
        EventId    BIGINT       NOT NULL,
        S          DATETIME2(3) NOT NULL,
        E          DATETIME2(3) NOT NULL,
        IsPlanned  BIT          NOT NULL,
        INDEX IX_Iv (LocationId, S)
    );

    INSERT INTO #Iv (LocationId, EventId, S, E, IsPlanned)
    SELECT u.LocationId,
           de.Id,
           CASE WHEN de.StartedAt > u.StartUtc THEN de.StartedAt ELSE u.StartUtc END,
           CASE WHEN COALESCE(de.EndedAt, @Now) < u.EndUtc THEN COALESCE(de.EndedAt, @Now) ELSE u.EndUtc END,
           COALESCE(rc.IsExcused, CAST(0 AS BIT))
    FROM #Unit u
    INNER JOIN #Src s               ON s.LocationId = u.LocationId
    INNER JOIN Oee.DowntimeEvent de ON de.LocationId = s.SourceLocationId
    LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
    WHERE de.VoidedAt IS NULL
      AND de.StartedAt < u.EndUtc
      AND COALESCE(de.EndedAt, @Now) > u.StartUtc;

    -- ================================================================
    -- 4. Merge by TIME, not by adding events up: two events that overlap cost
    --    the operator one stretch of clock, and a minute covered by anything
    --    PLANNED is planned. Measured on a minute grid (each minute's
    --    midpoint) -- exact for minute-aligned events; a second-precision
    --    live event carries at most about a minute's error per edge (see
    --    MINUTE GRID above).
    -- ================================================================
    ;WITH D(n) AS (
        SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) v(n)
    ),
    Tally(n) AS (
        SELECT a.n + 10*b.n + 100*c.n + 1000*d.n
        FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d   -- 0..9999 minutes: ~6.9 days, ample for any shift + override
    ),
    Slot AS (
        SELECT u.LocationId, DATEADD(SECOND, 30 + 60 * t.n, u.StartUtc) AS Mid
        FROM #Unit u
        INNER JOIN Tally t ON t.n < DATEDIFF(MINUTE, u.StartUtc, u.EndUtc)
        WHERE EXISTS (SELECT 1 FROM #Iv iv WHERE iv.LocationId = u.LocationId)
    ),
    Cover AS (
        SELECT s.LocationId, s.Mid, MAX(CAST(iv.IsPlanned AS INT)) AS AnyPlanned
        FROM Slot s
        INNER JOIN #Iv iv ON iv.LocationId = s.LocationId
                         AND iv.S <= s.Mid
                         AND iv.E >  s.Mid
        GROUP BY s.LocationId, s.Mid
    )
    UPDATE u
       SET PlannedDowntimeMinutes   = x.Planned,
           UnplannedDowntimeMinutes = x.Unplanned
    FROM #Unit u
    INNER JOIN (
        SELECT LocationId,
               SUM(CASE WHEN AnyPlanned = 1 THEN 1 ELSE 0 END) AS Planned,
               SUM(CASE WHEN AnyPlanned = 0 THEN 1 ELSE 0 END) AS Unplanned
        FROM Cover
        GROUP BY LocationId
    ) x ON x.LocationId = u.LocationId;

    UPDATE u
       SET DowntimeEventCount = c.Cnt
    FROM #Unit u
    INNER JOIN (SELECT LocationId, COUNT(DISTINCT EventId) AS Cnt FROM #Iv GROUP BY LocationId) c
        ON c.LocationId = u.LocationId;

    -- ================================================================
    -- 5. Leaf availability. PLANNED downtime shrinks the base (a lunch break
    --    is not a loss); UNPLANNED downtime comes off what is left.
    -- ================================================================
    UPDATE #Unit
       SET AvailabilityRaw =
               CASE
                   WHEN PlannedMinutes - PlannedDowntimeMinutes <= 0 THEN NULL
                   WHEN PlannedMinutes - PlannedDowntimeMinutes - UnplannedDowntimeMinutes <= 0 THEN 0
                   ELSE CAST(PlannedMinutes - PlannedDowntimeMinutes - UnplannedDowntimeMinutes AS DECIMAL(28,10))
                        / (PlannedMinutes - PlannedDowntimeMinutes)
               END,
           Done = 1
    WHERE IsRollup = 0;

    -- ================================================================
    -- 6. Roll-ups, deepest first: the unweighted mean of the flagged units
    --    directly beneath. AVG ignores NULL children (a zero base), and a
    --    roll-up whose children are all NULL stays NULL.
    -- ================================================================
    WHILE EXISTS (SELECT 1 FROM #Unit WHERE Done = 0)
    BEGIN
        UPDATE u
           SET AvailabilityRaw = c.AvgAvailability,
               Done            = 1
        FROM #Unit u
        CROSS APPLY (
            SELECT AVG(ch.AvailabilityRaw) AS AvgAvailability
            FROM #Unit ch
            WHERE ch.FlaggedParentId = u.LocationId
              AND ch.AvailabilityRaw IS NOT NULL
        ) c
        WHERE u.Done = 0
          AND NOT EXISTS (SELECT 1 FROM #Unit ch WHERE ch.FlaggedParentId = u.LocationId AND ch.Done = 0);

        IF @@ROWCOUNT = 0 BREAK;   -- defensive: a parent cycle would otherwise spin
    END

    -- ================================================================
    -- 7. Result
    -- ================================================================
    SELECT
        @ShiftId                  AS ShiftId,
        u.ShiftScheduleId,
        u.ScheduleName,
        u.BusinessDate,
        u.LocationId,
        u.Code                    AS LocationCode,
        u.Name                    AS LocationName,
        u.StartLocal,
        u.EndLocal,
        u.PlannedMinutes,
        u.PlannedDowntimeMinutes + u.UnplannedDowntimeMinutes AS DowntimeMinutes,
        u.UnplannedDowntimeMinutes AS UnexcusedDowntimeMinutes,
        CASE WHEN b.BaseMinutes - u.UnplannedDowntimeMinutes < 0
             THEN 0 ELSE b.BaseMinutes - u.UnplannedDowntimeMinutes END AS RunMinutes,
        CAST(u.AvailabilityRaw AS DECIMAL(5,4)) AS Availability,
        u.DowntimeEventCount,
        u.IsOverridden,
        u.ShiftOverrideId,
        u.OverrideReason,
        u.PlannedDowntimeMinutes,
        u.UnplannedDowntimeMinutes,
        b.BaseMinutes,
        u.IsRollup,
        u.FlaggedParentId         AS ParentLocationId
    FROM #Unit u
    CROSS APPLY (
        SELECT CASE WHEN u.PlannedMinutes - u.PlannedDowntimeMinutes < 0
                    THEN 0 ELSE u.PlannedMinutes - u.PlannedDowntimeMinutes END AS BaseMinutes
    ) b
    WHERE @LocationId IS NULL OR u.LocationId = @LocationId
    ORDER BY u.ParentName, u.SortOrder, u.Name;
END
GO
