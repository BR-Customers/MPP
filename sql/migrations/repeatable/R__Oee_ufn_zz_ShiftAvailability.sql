-- =============================================
-- Repeatable:  R__Oee_ufn_zz_ShiftAvailability.sql
-- Object:      Oee.ufn_ShiftAvailability
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     2.0
--
-- Description:
--   THE availability calculation: per OEE unit, for one runtime shift instance
--   (OEE dashboard spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--   v0.3.1 sec 6.1, D17). Oee.Shift_GetAvailability is a SELECT from it; the
--   dashboard's shift summary computes from it.
--
--   v2.0 -- SUMMED DURATIONS, attributed by ShiftId:
--     PlannedMinutes  = the unit's scheduled window for the shift (+ override)
--     Downtime        = SUM of the durations (Oee.ufn_DowntimeEventMinutes) of
--                       the entries with DowntimeEvent.ShiftId = @ShiftId, not
--                       voided, at the unit or (for a leaf) a flagged ancestor
--     PlannedDowntime = entries whose reason IsExcused; every other entry,
--                       including one with no reason, is unplanned
--     BaseMinutes     = max(0, PlannedMinutes - PlannedDowntime)
--     Unplanned       capped at BaseMinutes
--     Availability    = (Base - Unplanned) / Base, NULL when Base = 0
--     A roll-up (a unit with flagged units beneath) = the unweighted mean of the
--     flagged units directly beneath (AVG ignores NULL), deepest first.
--   v1.x merged entries by CLOCK position on a one-minute grid. MPP's downtime is
--   mostly a duration entered at the end of the shift, stored at the shift start,
--   so two such entries overlapped and were counted once. The clock merge also
--   counted an entry against any shift its clock time touched, whatever shift it
--   was entered for. Both are gone. Duplicates entered twice now count twice; the
--   dashboard's entry list is where they show.
--   Minute columns are rounded once to INT; Availability is computed from the
--   unrounded minutes and rounded once to DECIMAL(5,4).
--
--   Multi-statement TVF on table variables; the roll-up is computed deepest
--   first in a WHILE loop.
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
--   2026-10-30 - 2.0 - Summed entered durations attributed by ShiftId (spec v0.3.1 D17); the
--                      clock-overlap minute grid is removed. Unplanned capped at the base.
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
        PlannedDowntimeRaw       DECIMAL(14,4) NOT NULL DEFAULT 0,
        UnplannedDowntimeRaw     DECIMAL(14,4) NOT NULL DEFAULT 0,
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
    -- 3. The shift's entries, by ShiftId, summed per unit (D17)
    -- ================================================================
    UPDATE u
       SET PlannedDowntimeRaw   = x.Planned,
           UnplannedDowntimeRaw = x.Unplanned,
           DowntimeEventCount   = x.Cnt
    FROM @Unit u
    INNER JOIN (
        SELECT u2.LocationId,
               SUM(CASE WHEN COALESCE(rc.IsExcused, CAST(0 AS BIT)) = 1 THEN m.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN COALESCE(rc.IsExcused, CAST(0 AS BIT)) = 1 THEN 0 ELSE m.Minutes END) AS Unplanned,
               COUNT(*)                                                                         AS Cnt
        FROM @Unit u2
        INNER JOIN @Src s               ON s.LocationId = u2.LocationId
        INNER JOIN Oee.DowntimeEvent de ON de.LocationId = s.SourceLocationId
        LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
        CROSS APPLY Oee.ufn_DowntimeEventMinutes(
            de.IsApproximate, de.DurationMinutes, de.StartedAt, de.EndedAt,
            CASE WHEN @Now < u2.EndUtc THEN @Now ELSE u2.EndUtc END) m
        WHERE de.ShiftId = @ShiftId
          AND de.VoidedAt IS NULL
        GROUP BY u2.LocationId
    ) x ON x.LocationId = u.LocationId;

    -- ================================================================
    -- 5. Leaf availability: planned downtime shrinks the base; unplanned
    --    downtime comes off what is left.
    -- ================================================================
    UPDATE u
       SET AvailabilityRaw =
               CASE
                   WHEN b.Base <= 0                          THEN NULL
                   WHEN u.UnplannedDowntimeRaw >= b.Base     THEN 0
                   ELSE (b.Base - u.UnplannedDowntimeRaw) / b.Base
               END,
           Done = 1
    FROM @Unit u
    CROSS APPLY (SELECT CAST(u.PlannedMinutes AS DECIMAL(14,4)) - u.PlannedDowntimeRaw AS Base) b
    WHERE u.IsRollup = 0;

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
        r.EnteredDowntime,
        r.Unplanned,
        CASE WHEN r.Base - r.Unplanned < 0 THEN 0 ELSE r.Base - r.Unplanned END,
        CAST(u.AvailabilityRaw AS DECIMAL(5,4)),
        u.DowntimeEventCount,
        u.IsOverridden,
        u.ShiftOverrideId,
        u.OverrideReason,
        r.PlannedDowntime,
        r.Unplanned,
        r.Base,
        u.IsRollup,
        u.FlaggedParentId,
        u.ParentName,
        u.SortOrder
    FROM @Unit u
    CROSS APPLY (
        SELECT CASE WHEN u.PlannedMinutes - u.PlannedDowntimeRaw < 0 THEN 0
                    ELSE CAST(ROUND(u.PlannedMinutes - u.PlannedDowntimeRaw, 0) AS INT) END AS Base
    ) b
    CROSS APPLY (
        SELECT b.Base                                                        AS Base,
               CAST(ROUND(u.PlannedDowntimeRaw, 0) AS INT)                   AS PlannedDowntime,
               CAST(ROUND(u.PlannedDowntimeRaw + u.UnplannedDowntimeRaw, 0) AS INT) AS EnteredDowntime,
               CASE WHEN ROUND(u.UnplannedDowntimeRaw, 0) > b.Base THEN b.Base
                    ELSE CAST(ROUND(u.UnplannedDowntimeRaw, 0) AS INT) END   AS Unplanned
    ) r;

    RETURN;
END
GO
