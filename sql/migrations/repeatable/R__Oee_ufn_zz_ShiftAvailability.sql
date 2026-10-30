-- =============================================
-- Repeatable:  R__Oee_ufn_zz_ShiftAvailability.sql
-- Object:      Oee.ufn_ShiftAvailability
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.1
--
-- Description:
--   THE availability calculation: per OEE unit, for one runtime shift instance.
--   Moved out of Oee.Shift_GetAvailability v2.0.1 unchanged in behaviour, so the
--   OEE dashboard procs can read it per shift (spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md sec 6.1). A proc
--   cannot share it any other way: the dashboard procs are captured by tests
--   with INSERT-EXEC, and INSERT-EXEC cannot nest.
--
--   Oee.Shift_GetAvailability v3.0 is now a SELECT from this function; read
--   that proc's header for the four deliberate choices (schedule-based planned
--   time, downtime matched by time overlap, planned downtime shrinks the base,
--   ancestor inheritance + mean roll-up), the minute grid and the time basis.
--   They all hold here verbatim.
--
--   Multi-statement TVF on table variables: the roll-up is computed deepest
--   first in a WHILE loop, as before. Table variables carry no statistics; the
--   dashboard benchmark (plan Task 7) is the check that this is fast enough.
--
--   FILE NAME IS ORDER-SENSITIVE -- 'zz_' is a DEPLOY-ORDER MARKER, not part of
--   the object name. A FUNCTION gets no deferred name resolution (Msg 4121) and
--   this one calls Oee.ufn_ShiftWindowForLocation, which would sort AFTER
--   'ShiftAvailability'. Same convention as R__Oee_ufn_zz_ShiftIdForInstant.
--
-- Parameters:
--   @ShiftId BIGINT - Runtime Oee.Shift instance. Unknown -> no rows.
--
-- Result (one row per OEE unit): the columns of Oee.Shift_GetAvailability, in
--   its order, plus two trailing sort keys the proc orders by and does not
--   return: SortParentName, SortOrder.
--
-- Change Log:
--   2026-10-29 - 1.0 - Extracted from Oee.Shift_GetAvailability v2.0.1.
--   2026-10-29 - 1.1 - Minute grid enumerates only the minutes inside each interval (same
--                      coverage test). Benchmark: ~1.3 s -> ~0.7 s per shift; still the
--                      largest cost (plan Task 7 gate).
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftAvailability
(
    @ShiftId BIGINT
)
RETURNS @Result TABLE (
    ShiftId                  BIGINT        NULL,
    ShiftScheduleId          BIGINT        NULL,
    ScheduleName             NVARCHAR(100) NULL,
    BusinessDate             DATE          NULL,
    LocationId               BIGINT        NOT NULL,
    LocationCode             NVARCHAR(50)  NULL,
    LocationName             NVARCHAR(200) NULL,
    StartLocal               DATETIME2(3)  NULL,
    EndLocal                 DATETIME2(3)  NULL,
    PlannedMinutes           INT           NULL,
    DowntimeMinutes          INT           NULL,
    UnexcusedDowntimeMinutes INT           NULL,
    RunMinutes               INT           NULL,
    Availability             DECIMAL(5,4)  NULL,
    DowntimeEventCount       INT           NULL,
    IsOverridden             BIT           NULL,
    ShiftOverrideId          BIGINT        NULL,
    OverrideReason           NVARCHAR(500) NULL,
    PlannedDowntimeMinutes   INT           NULL,
    UnplannedDowntimeMinutes INT           NULL,
    BaseMinutes              INT           NULL,
    IsRollup                 BIT           NULL,
    ParentLocationId         BIGINT        NULL,
    SortParentName           NVARCHAR(200) NULL,
    SortOrder                INT           NULL
)
AS
BEGIN
    -- ActualStart is LOCAL (OI-38) -- cast straight to DATE, no conversion.
    DECLARE @SchedId      BIGINT;
    DECLARE @BusinessDate DATE;
    SELECT @SchedId      = s.ShiftScheduleId,
           @BusinessDate = CAST(s.ActualStart AS DATE)
    FROM Oee.Shift s
    WHERE s.Id = @ShiftId;

    IF @SchedId IS NULL
        RETURN;   -- no rows = shift not found

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    -- ================================================================
    -- 1. Every OEE unit, its window, and its nearest flagged parent
    -- ================================================================
    DECLARE @Unit TABLE (
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

    INSERT INTO @Unit (LocationId, Code, Name, ParentName, SortOrder, FlaggedParentId,
                       ShiftScheduleId, ScheduleName, BusinessDate, StartLocal, EndLocal,
                       PlannedMinutes, StartUtc, EndUtc, IsOverridden, ShiftOverrideId, OverrideReason)
    SELECT e.LocationId, e.Code, e.Name, e.ParentName, e.SortOrder,
           (SELECT TOP 1 a.AncestorLocationId
            FROM Oee.ufn_OeeAncestors(e.LocationId) a
            ORDER BY a.Distance),
           w.ShiftScheduleId, w.ScheduleName, w.BusinessDate, w.StartLocal, w.EndLocal,
           w.DurationMinutes,
           -- Local window -> UTC for comparison against Oee.DowntimeEvent.StartedAt.
           CAST(w.StartLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
           CAST(w.EndLocal   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
           w.IsOverridden, w.ShiftOverrideId, w.OverrideReason
    FROM Oee.ufn_ResolveOeeEquipment() e
    CROSS APPLY Oee.ufn_ShiftWindowForLocation(e.LocationId, @SchedId, @BusinessDate) w;

    -- A unit with a flagged unit beneath it reports the MEAN of those units.
    UPDATE u
       SET IsRollup = 1
    FROM @Unit u
    WHERE EXISTS (SELECT 1 FROM @Unit c WHERE c.FlaggedParentId = u.LocationId);

    -- ================================================================
    -- 2. Which locations' downtime each unit counts: itself always; a LEAF
    --    also every flagged ancestor. A roll-up counts only its own events.
    -- ================================================================
    DECLARE @Src TABLE (
        LocationId       BIGINT NOT NULL,
        SourceLocationId BIGINT NOT NULL,
        PRIMARY KEY (LocationId, SourceLocationId)
    );

    INSERT INTO @Src (LocationId, SourceLocationId)
    SELECT u.LocationId, u.LocationId FROM @Unit u;

    INSERT INTO @Src (LocationId, SourceLocationId)
    SELECT u.LocationId, a.AncestorLocationId
    FROM @Unit u
    CROSS APPLY Oee.ufn_OeeAncestors(u.LocationId) a
    WHERE u.IsRollup = 0
      AND a.AncestorLocationId <> u.LocationId;

    -- ================================================================
    -- 3. Downtime intervals, clipped to each unit's own window
    -- ================================================================
    DECLARE @Iv TABLE (
        LocationId BIGINT       NOT NULL,
        EventId    BIGINT       NOT NULL,
        S          DATETIME2(3) NOT NULL,
        E          DATETIME2(3) NOT NULL,
        IsPlanned  BIT          NOT NULL,
        INDEX IX_Iv (LocationId, S)
    );

    INSERT INTO @Iv (LocationId, EventId, S, E, IsPlanned)
    SELECT u.LocationId,
           de.Id,
           CASE WHEN de.StartedAt > u.StartUtc THEN de.StartedAt ELSE u.StartUtc END,
           CASE WHEN COALESCE(de.EndedAt, @Now) < u.EndUtc THEN COALESCE(de.EndedAt, @Now) ELSE u.EndUtc END,
           COALESCE(rc.IsExcused, CAST(0 AS BIT))
    FROM @Unit u
    INNER JOIN @Src s               ON s.LocationId = u.LocationId
    INNER JOIN Oee.DowntimeEvent de ON de.LocationId = s.SourceLocationId
    LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
    WHERE de.VoidedAt IS NULL
      AND de.StartedAt < u.EndUtc
      AND COALESCE(de.EndedAt, @Now) > u.StartUtc;

    -- ================================================================
    -- 4. Merge by TIME on a minute grid (each minute's midpoint); a minute
    --    covered by anything PLANNED is planned.
    -- ================================================================
    --    Only the minutes INSIDE an interval are enumerated (v1.1): slot i
    --    (midpoint StartUtc + 30 s + 60 s * i) is covered by [S, E) exactly
    --    when Lo <= i <= Hi below -- the same test as "S <= mid < E", without
    --    building every minute of every unit and joining it to every interval.
    ;WITH D(n) AS (
        SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) v(n)
    ),
    Tally(n) AS (
        SELECT a.n + 10*b.n + 100*c.n + 1000*d.n
        FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d   -- 0..9999 minutes
    ),
    Rng AS (
        SELECT iv.LocationId, iv.IsPlanned,
               CASE WHEN r.Lo < 0 THEN 0 ELSE r.Lo END AS Lo,
               CASE WHEN r.Hi > r.SlotCount - 1 THEN r.SlotCount - 1 ELSE r.Hi END AS Hi
        FROM @Iv iv
        INNER JOIN @Unit u ON u.LocationId = iv.LocationId
        CROSS APPLY (
            SELECT CAST(CEILING((DATEDIFF_BIG(MILLISECOND, u.StartUtc, iv.S) - 30000) / 60000.0) AS INT)     AS Lo,
                   CAST(CEILING((DATEDIFF_BIG(MILLISECOND, u.StartUtc, iv.E) - 30000) / 60000.0) AS INT) - 1 AS Hi,
                   DATEDIFF(MINUTE, u.StartUtc, u.EndUtc)                                                    AS SlotCount
        ) r
    ),
    Cover AS (
        SELECT g.LocationId, s.n AS Slot, MAX(CAST(g.IsPlanned AS INT)) AS AnyPlanned
        FROM Rng g
        CROSS APPLY (
            SELECT TOP (CASE WHEN g.Hi >= g.Lo THEN g.Hi - g.Lo + 1 ELSE 0 END) g.Lo + t.n AS n
            FROM Tally t
            ORDER BY t.n
        ) s
        GROUP BY g.LocationId, s.n
    )
    UPDATE u
       SET PlannedDowntimeMinutes   = x.Planned,
           UnplannedDowntimeMinutes = x.Unplanned
    FROM @Unit u
    INNER JOIN (
        SELECT LocationId,
               SUM(CASE WHEN AnyPlanned = 1 THEN 1 ELSE 0 END) AS Planned,
               SUM(CASE WHEN AnyPlanned = 0 THEN 1 ELSE 0 END) AS Unplanned
        FROM Cover
        GROUP BY LocationId
    ) x ON x.LocationId = u.LocationId;

    UPDATE u
       SET DowntimeEventCount = c.Cnt
    FROM @Unit u
    INNER JOIN (SELECT LocationId, COUNT(DISTINCT EventId) AS Cnt FROM @Iv GROUP BY LocationId) c
        ON c.LocationId = u.LocationId;

    -- ================================================================
    -- 5. Leaf availability: planned downtime shrinks the base; unplanned
    --    downtime comes off what is left.
    -- ================================================================
    UPDATE @Unit
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
    --    directly beneath. AVG ignores NULL children.
    -- ================================================================
    DECLARE @Rows INT = 1;
    WHILE @Rows > 0 AND EXISTS (SELECT 1 FROM @Unit WHERE Done = 0)
    BEGIN
        UPDATE u
           SET AvailabilityRaw = c.AvgAvailability,
               Done            = 1
        FROM @Unit u
        CROSS APPLY (
            SELECT AVG(ch.AvailabilityRaw) AS AvgAvailability
            FROM @Unit ch
            WHERE ch.FlaggedParentId = u.LocationId
              AND ch.AvailabilityRaw IS NOT NULL
        ) c
        WHERE u.Done = 0
          AND NOT EXISTS (SELECT 1 FROM @Unit ch WHERE ch.FlaggedParentId = u.LocationId AND ch.Done = 0);

        SET @Rows = @@ROWCOUNT;   -- defensive: a parent cycle would otherwise spin
    END

    -- ================================================================
    -- 7. Result
    -- ================================================================
    INSERT INTO @Result
    SELECT
        @ShiftId,
        u.ShiftScheduleId,
        u.ScheduleName,
        u.BusinessDate,
        u.LocationId,
        u.Code,
        u.Name,
        u.StartLocal,
        u.EndLocal,
        u.PlannedMinutes,
        u.PlannedDowntimeMinutes + u.UnplannedDowntimeMinutes,
        u.UnplannedDowntimeMinutes,
        CASE WHEN b.BaseMinutes - u.UnplannedDowntimeMinutes < 0
             THEN 0 ELSE b.BaseMinutes - u.UnplannedDowntimeMinutes END,
        CAST(u.AvailabilityRaw AS DECIMAL(5,4)),
        u.DowntimeEventCount,
        u.IsOverridden,
        u.ShiftOverrideId,
        u.OverrideReason,
        u.PlannedDowntimeMinutes,
        u.UnplannedDowntimeMinutes,
        b.BaseMinutes,
        u.IsRollup,
        u.FlaggedParentId,
        u.ParentName,
        u.SortOrder
    FROM @Unit u
    CROSS APPLY (
        SELECT CASE WHEN u.PlannedMinutes - u.PlannedDowntimeMinutes < 0
                    THEN 0 ELSE u.PlannedMinutes - u.PlannedDowntimeMinutes END AS BaseMinutes
    ) b;

    RETURN;
END
GO
