-- =============================================
-- Repeatable:  R__Oee_ufn_zzzz_ShiftSummaryRows.sql
-- Object:      Oee.ufn_ShiftSummaryRows
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   THE per-shift OEE figures (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.1 sec 6.3,
--   6.7, D16): one shift's minutes and counts for every placement, the rows
--   Oee.ShiftSummary stores. Oee.ShiftSummary_ComputeCore writes them for a
--   closed shift; the dashboard reads this function live for the shift in
--   progress (and for a closed shift not stored yet). One calculation, so a
--   stored shift and a live shift can never disagree.
--
--   Minutes and counts only -- never a percentage; the readers pool (6.3).
--
--   Rows (RowKind):
--     Unit          every OEE unit (Oee.ufn_OeeUnits IsStation = 0).
--                   PlannedMinutes / BaseMinutes / EffectiveUnplannedMinutes
--                   from Oee.ufn_ShiftAvailability: Base is 0 when the unit's
--                   availability is NULL (no base); a roll-up line's effective
--                   unplanned is Base * (1 - its station mean), anything else
--                   its capped unplanned minutes. Downtime minutes / counts /
--                   no-reason are the ENTERED entries placed on the unit by
--                   Oee.ufn_AreaFamily (its own and its stations'). Good and
--                   Scrap are what landed on the unit; NonRejectScrap is the
--                   non-reject scrap found there. Trim presses carry no good or
--                   scrap (D5) -- trim quality is the shop's AreaPlacement row.
--                   LastToolId = the die of its latest die-cast credit.
--                   IsActive = good, scrap, or a downtime entry this shift at
--                   the unit or its stations; a trim press is active when its
--                   shop made or scrapped anything (6.3).
--     Station       every OEE station under a unit: its own availability
--                   minutes and its own entered downtime. IsActive = its top
--                   unit's (stations pool over the unit's active shifts).
--     AreaPlacement a ProductionArea that good, scrap or downtime is booked on
--                   directly (the trim shop, D5): Good, Scrap, NonRejectScrap,
--                   entered downtime. Written only when something is there.
--     AreaCharge    one per family (diecast | trim | ma) -- ALL scrap charged to
--                   the family by defect code (Scrap, NonRejectScrap), of which
--                   FoundDownstreamScrap was found elsewhere or with no cell --
--                   plus one row with AreaFamily NULL: UnplacedScrap /
--                   NonRejectScrap for Non-Specific rejects with no cell.
--   Shift membership of entries / scrap / good is the existing functions'
--   (ufn_ShiftAvailability, ufn_ShiftGood, ufn_ShiftScrap); entered downtime
--   is DowntimeEvent.ShiftId, duration by Oee.ufn_DowntimeEventMinutes.
--
--   Multi-statement TVF (readers cannot INSERT-EXEC a proc inside a test that
--   is itself an INSERT-EXEC). Unknown shift -> no rows.
--
--   FILE NAME IS ORDER-SENSITIVE -- 'zzzz_' sorts after the 'zz_' / 'zzz_'
--   functions it calls (Oee.ufn_ShiftAvailability, ufn_AreaFamily,
--   ufn_ShiftGood, ufn_ShiftScrap).
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version (logic moved out of Dashboard_GetUnitSummary v1.0).
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftSummaryRows (@ShiftId BIGINT)
RETURNS @Out TABLE (
    ShiftId                   BIGINT        NOT NULL,
    LocationId                BIGINT        NULL,
    RowKind                   NVARCHAR(15)  NOT NULL,
    AreaFamily                NVARCHAR(10)  NULL,
    ProductionAreaId          BIGINT        NULL,
    ParentUnitLocationId      BIGINT        NULL,
    PlannedMinutes            INT           NOT NULL,
    PlannedDowntimeMinutes    DECIMAL(12,2) NOT NULL,
    UnplannedDowntimeMinutes  DECIMAL(12,2) NOT NULL,
    BaseMinutes               INT           NOT NULL,
    EffectiveUnplannedMinutes DECIMAL(12,4) NOT NULL,
    DowntimeEventCount        INT           NOT NULL,
    NoReasonCount             INT           NOT NULL,
    NoReasonMinutes           DECIMAL(12,2) NOT NULL,
    Good                      BIGINT        NOT NULL,
    Scrap                     BIGINT        NOT NULL,
    NonRejectScrap            BIGINT        NOT NULL,
    FoundDownstreamScrap      BIGINT        NOT NULL,
    UnplacedScrap             BIGINT        NOT NULL,
    LastToolId                BIGINT        NULL,
    IsActive                  BIT           NOT NULL
)
AS
BEGIN
    DECLARE @SchedId BIGINT, @BusinessDate DATE;
    SELECT @SchedId = s.ShiftScheduleId, @BusinessDate = CAST(s.ActualStart AS DATE)
    FROM Oee.Shift s WHERE s.Id = @ShiftId;
    IF @SchedId IS NULL RETURN;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    -- ---- units ----
    DECLARE @U TABLE (LocationId BIGINT PRIMARY KEY, IsStation BIT, ParentUnitLocationId BIGINT,
                      TopUnitLocationId BIGINT, AreaFamily NVARCHAR(10), ProductionAreaId BIGINT);
    INSERT INTO @U
    SELECT LocationId, IsStation, ParentUnitLocationId, TopUnitLocationId, AreaFamily, ProductionAreaId
    FROM Oee.ufn_OeeUnits();

    -- ---- availability minutes ----
    DECLARE @Av TABLE (LocationId BIGINT PRIMARY KEY, Planned INT, Base INT, Eff DECIMAL(12,4));
    INSERT INTO @Av
    SELECT a.LocationId, ISNULL(a.PlannedMinutes, 0),
           CASE WHEN a.Availability IS NULL THEN 0 ELSE a.BaseMinutes END,
           CASE WHEN a.Availability IS NULL THEN 0
                WHEN a.IsRollup = 1 THEN a.BaseMinutes * (1 - CAST(a.Availability AS DECIMAL(19,6)))
                ELSE a.UnplannedDowntimeMinutes END
    FROM Oee.ufn_ShiftAvailability(@ShiftId) a;

    -- ---- good / scrap ----
    DECLARE @G TABLE (UnitLocationId BIGINT, PlacementIsArea BIT, AreaFamily NVARCHAR(10),
                      ToolId BIGINT, LastEventAt DATETIME2(3), Good BIGINT);
    INSERT INTO @G
    SELECT g.UnitLocationId, g.PlacementIsArea, g.AreaFamily, g.ToolId, g.LastEventAt, g.Good
    FROM Oee.ufn_ShiftGood(@ShiftId) g;

    DECLARE @S TABLE (ChargeFamily NVARCHAR(10), UnitLocationId BIGINT, PlacementIsArea BIT,
                      FoundAtLocationId BIGINT, Quantity BIGINT, IsNonReject BIT, IsFoundDownstream BIT);
    INSERT INTO @S
    SELECT s.ChargeFamily, s.UnitLocationId, s.PlacementIsArea, s.FoundAtLocationId,
           s.Quantity, s.IsNonReject, s.IsFoundDownstream
    FROM Oee.ufn_ShiftScrap(@ShiftId) s;

    -- ---- entered downtime, placed ----
    DECLARE @D TABLE (LocationId BIGINT, PlacementLocationId BIGINT, PlacementIsArea BIT, AreaFamily NVARCHAR(10),
                      Minutes DECIMAL(12,4), IsPlanned BIT, IsNoReason BIT);
    INSERT INTO @D
    SELECT de.LocationId, af.PlacementLocationId, af.PlacementIsArea, af.AreaFamily, m.Minutes,
           CAST(ISNULL(rc.IsExcused, 0) AS BIT),
           CAST(CASE WHEN de.DowntimeReasonCodeId IS NULL THEN 1 ELSE 0 END AS BIT)
    FROM Oee.DowntimeEvent de
    LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
    CROSS APPLY Oee.ufn_AreaFamily(de.LocationId) af
    OUTER APPLY (SELECT TOP 1 w.EndLocal FROM Oee.ufn_ShiftWindowForLocation(de.LocationId, @SchedId, @BusinessDate) w) win
    CROSS APPLY Oee.ufn_DowntimeEventMinutes(de.IsApproximate, de.DurationMinutes, de.StartedAt, de.EndedAt,
        CASE WHEN win.EndLocal IS NULL THEN @Now
             WHEN CAST(win.EndLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) < @Now
                 THEN CAST(win.EndLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))
             ELSE @Now END) m
    WHERE de.ShiftId = @ShiftId
      AND de.VoidedAt IS NULL;

    -- ---- active units (6.3) ----
    DECLARE @Act TABLE (LocationId BIGINT PRIMARY KEY);
    INSERT INTO @Act (LocationId)
    SELECT u.LocationId
    FROM @U u
    WHERE u.IsStation = 0
      AND (   EXISTS (SELECT 1 FROM @G g WHERE g.UnitLocationId = u.LocationId AND g.PlacementIsArea = 0)
           OR EXISTS (SELECT 1 FROM @S s WHERE s.FoundAtLocationId = u.LocationId)
           OR EXISTS (SELECT 1 FROM @D d WHERE d.PlacementLocationId = u.LocationId)
           OR (u.AreaFamily = N'trim' AND (
                  EXISTS (SELECT 1 FROM @G g WHERE g.UnitLocationId = u.ProductionAreaId AND g.PlacementIsArea = 1)
               OR EXISTS (SELECT 1 FROM @S s WHERE s.FoundAtLocationId = u.ProductionAreaId))));

    -- ---- Unit rows ----
    INSERT INTO @Out
    SELECT @ShiftId, u.LocationId, N'Unit', u.AreaFamily, u.ProductionAreaId, NULL,
           ISNULL(av.Planned, 0),
           ISNULL(dt.Planned, 0), ISNULL(dt.Unplanned, 0),
           ISNULL(av.Base, 0), ISNULL(av.Eff, 0),
           ISNULL(dt.Cnt, 0), ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0),
           CASE WHEN u.AreaFamily = N'trim' THEN 0 ELSE ISNULL(gd.Good, 0) END,
           CASE WHEN u.AreaFamily = N'trim' THEN 0 ELSE ISNULL(sc.Scrap, 0) END,
           ISNULL(nr.NonReject, 0), 0, 0,
           tl.ToolId,
           CASE WHEN EXISTS (SELECT 1 FROM @Act a WHERE a.LocationId = u.LocationId) THEN 1 ELSE 0 END
    FROM @U u
    LEFT JOIN @Av av ON av.LocationId = u.LocationId
    OUTER APPLY (
        SELECT SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               COUNT(*)                                                AS Cnt,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END)       AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.PlacementLocationId = u.LocationId AND d.PlacementIsArea = 0
    ) dt
    OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.UnitLocationId = u.LocationId AND g.PlacementIsArea = 0) gd
    OUTER APPLY (SELECT SUM(s.Quantity) AS Scrap FROM @S s
                 WHERE s.IsNonReject = 0 AND s.UnitLocationId = u.LocationId AND s.PlacementIsArea = 0) sc
    OUTER APPLY (SELECT SUM(s.Quantity) AS NonReject FROM @S s
                 WHERE s.IsNonReject = 1 AND s.FoundAtLocationId = u.LocationId) nr
    OUTER APPLY (SELECT TOP 1 g.ToolId FROM @G g
                 WHERE g.UnitLocationId = u.LocationId AND g.PlacementIsArea = 0 AND g.ToolId IS NOT NULL
                 ORDER BY g.LastEventAt DESC) tl
    WHERE u.IsStation = 0;

    -- ---- Station rows ----
    INSERT INTO @Out
    SELECT @ShiftId, u.LocationId, N'Station', u.AreaFamily, u.ProductionAreaId, u.ParentUnitLocationId,
           ISNULL(av.Planned, 0),
           ISNULL(dt.Planned, 0), ISNULL(dt.Unplanned, 0),
           ISNULL(av.Base, 0), ISNULL(av.Eff, 0),
           ISNULL(dt.Cnt, 0), ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0),
           0, 0, 0, 0, 0, NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @Act a WHERE a.LocationId = u.TopUnitLocationId) THEN 1 ELSE 0 END
    FROM @U u
    LEFT JOIN @Av av ON av.LocationId = u.LocationId
    OUTER APPLY (
        SELECT SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               COUNT(*)                                                AS Cnt,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END)       AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.LocationId = u.LocationId
    ) dt
    WHERE u.IsStation = 1;

    -- ---- AreaPlacement rows ----
    ;WITH Areas AS (
        SELECT UnitLocationId AS AreaId, AreaFamily FROM @G WHERE PlacementIsArea = 1
        UNION SELECT UnitLocationId, ChargeFamily FROM @S WHERE PlacementIsArea = 1 AND UnitLocationId IS NOT NULL
        UNION SELECT s.FoundAtLocationId, af.AreaFamily FROM @S s
              CROSS APPLY Oee.ufn_AreaFamily(s.FoundAtLocationId) af
              WHERE s.IsNonReject = 1 AND af.PlacementIsArea = 1 AND af.PlacementLocationId = s.FoundAtLocationId
        UNION SELECT PlacementLocationId, AreaFamily FROM @D WHERE PlacementIsArea = 1
    )
    INSERT INTO @Out
    SELECT @ShiftId, a.AreaId, N'AreaPlacement', MAX(a.AreaFamily), a.AreaId, NULL,
           0,
           ISNULL(MAX(dt.Planned), 0), ISNULL(MAX(dt.Unplanned), 0),
           0, 0,
           ISNULL(MAX(dt.Cnt), 0), ISNULL(MAX(dt.NoReasonCount), 0), ISNULL(MAX(dt.NoReasonMinutes), 0),
           ISNULL(MAX(gd.Good), 0), ISNULL(MAX(sc.Scrap), 0), ISNULL(MAX(nr.NonReject), 0), 0, 0, NULL,
           CASE WHEN ISNULL(MAX(gd.Good), 0) + ISNULL(MAX(sc.Scrap), 0) + ISNULL(MAX(nr.NonReject), 0) + ISNULL(MAX(dt.Cnt), 0) > 0
                THEN 1 ELSE 0 END
    FROM Areas a
    OUTER APPLY (
        SELECT SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               COUNT(*)                                                AS Cnt,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END)       AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.PlacementLocationId = a.AreaId AND d.PlacementIsArea = 1
    ) dt
    OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.UnitLocationId = a.AreaId AND g.PlacementIsArea = 1) gd
    OUTER APPLY (SELECT SUM(s.Quantity) AS Scrap FROM @S s
                 WHERE s.IsNonReject = 0 AND s.UnitLocationId = a.AreaId AND s.PlacementIsArea = 1) sc
    OUTER APPLY (SELECT SUM(s.Quantity) AS NonReject FROM @S s
                 WHERE s.IsNonReject = 1 AND s.FoundAtLocationId = a.AreaId) nr
    WHERE a.AreaId IS NOT NULL
    GROUP BY a.AreaId;

    -- ---- AreaCharge rows: one per family + the unplaced (NULL family) row ----
    INSERT INTO @Out
    SELECT @ShiftId, NULL, N'AreaCharge', f.AreaFamily, NULL, NULL,
           0, 0, 0, 0, 0, 0, 0, 0,
           0,
           CASE WHEN f.AreaFamily IS NULL THEN 0 ELSE ISNULL(x.Reject, 0) END,
           ISNULL(x.NonReject, 0),
           CASE WHEN f.AreaFamily IS NULL THEN 0 ELSE ISNULL(x.Downstream, 0) END,
           CASE WHEN f.AreaFamily IS NULL THEN ISNULL(x.Reject, 0) ELSE 0 END,
           NULL,
           CASE WHEN ISNULL(x.Reject, 0) + ISNULL(x.NonReject, 0) > 0 THEN 1 ELSE 0 END
    FROM (VALUES (N'diecast'), (N'trim'), (N'ma'), (NULL)) f (AreaFamily)
    OUTER APPLY (
        -- the family test stays in WHERE: an aggregate may not mix an outer
        -- reference with other columns (Msg 8124)
        SELECT SUM(CASE WHEN s.IsNonReject = 0 THEN s.Quantity ELSE 0 END)                              AS Reject,
               SUM(CASE WHEN s.IsNonReject = 1 THEN s.Quantity ELSE 0 END)                              AS NonReject,
               SUM(CASE WHEN s.IsNonReject = 0 AND s.IsFoundDownstream = 1 THEN s.Quantity ELSE 0 END)  AS Downstream
        FROM @S s
        WHERE (f.AreaFamily IS NOT NULL AND s.ChargeFamily = f.AreaFamily)
           OR (f.AreaFamily IS NULL AND s.ChargeFamily IS NULL)
    ) x;

    RETURN;
END
GO
