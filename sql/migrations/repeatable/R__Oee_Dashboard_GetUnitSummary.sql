-- =============================================
-- Procedure:   Oee.Dashboard_GetUnitSummary
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
--
-- Description:
--   The OEE dashboard's main read (spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md sec 5.2-5.3,
--   6.3, 8): availability, downtime and quality for a period, one row per
--     Unit     a press, trim press or line (Oee.ufn_OeeUnits IsStation = 0)
--     Station  an OEE-enabled station under a line (availability + downtime)
--     Group    a ProductionArea (Die Cast 1-4, Trim Shop 1-2, M&A 1-2, ...)
--     Area     a family: diecast | trim | ma
--     Plant    the whole plant (always returned, whatever @AreaFamily says)
--
--   POOLED, NEVER AVERAGED (sec 6.3):
--     Availability = SUM(Base - Unplanned) / SUM(Base)
--     Quality      = SUM(Good) / SUM(Good + Scrap)     (non-reject scrap excluded)
--   over (unit, shift) pairs. A roll-up line pools as Base * (1 - its station
--   mean), so its own figure stays exactly what Oee.ufn_ShiftAvailability
--   reports. Only ACTIVE pairs pool: a unit-shift with good, scrap or a
--   downtime event (a trim press is active when its shop made or scrapped
--   anything that shift). An idle press would otherwise report 100% and
--   dilute its area (anti-goal, sec 2). A unit with no active shift has
--   HasProduction = 0 and Availability NULL ("No production").
--
--   Downtime MINUTES (DowntimeMinutes / Planned / Unplanned / NoReason) are the
--   entered events summed by duration, matched to the period by
--   DowntimeEvent.ShiftId and placed with Oee.ufn_AreaFamily -- what the
--   operator entered, the same basis as the Pareto. Availability uses the
--   time-merged minutes of Oee.ufn_ShiftAvailability (EffectiveUnplannedMinutes).
--   An event with no reason counts as unplanned.
--
--   Scrap is charged by defect code (Oee.ufn_ShiftScrap): on a Unit or Group
--   only when found in its own family; at Area level also the area's
--   found-downstream scrap; at Plant level everything charged to an area.
--   UnplacedScrap (Plant row) = Non-Specific rejects with no cell.
--   Trim press Unit rows carry no good/scrap/quality (D5): trim quality is
--   the shop's (Group row).
--
--   Read proc: ONE result set, no OUTPUT params (FDS-11-011). Unknown anchor
--   or zoom -> no rows.
--
-- Parameters:
--   @Zoom          NVARCHAR(5)  - Shift | Day | Week
--   @AnchorShiftId BIGINT       - a shift in the period
--   @AreaFamily    NVARCHAR(10) - NULL = all; else diecast | trim | ma
--
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetUnitSummary
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT,
    @AreaFamily    NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    -- ---- 1. The period's shifts ----
    DECLARE @Sh TABLE (ShiftId BIGINT PRIMARY KEY, IsOpen BIT);
    INSERT INTO @Sh (ShiftId, IsOpen)
    SELECT p.ShiftId, CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END
    FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
    INNER JOIN Oee.Shift s ON s.Id = p.ShiftId;

    DECLARE @InProgress BIT = CASE WHEN EXISTS (SELECT 1 FROM @Sh WHERE IsOpen = 1) THEN 1 ELSE 0 END;

    -- ---- 2. Units ----
    DECLARE @U TABLE (
        LocationId BIGINT PRIMARY KEY, Code NVARCHAR(50), Name NVARCHAR(200), DefinitionCode NVARCHAR(50),
        SortOrder INT, IsStation BIT, ParentUnitLocationId BIGINT, TopUnitLocationId BIGINT,
        AreaFamily NVARCHAR(10), ProductionAreaId BIGINT, ProductionAreaName NVARCHAR(200), ProductionAreaSortOrder INT);
    INSERT INTO @U
    SELECT LocationId, Code, Name, DefinitionCode, SortOrder, IsStation, ParentUnitLocationId, TopUnitLocationId,
           AreaFamily, ProductionAreaId, ProductionAreaName, ProductionAreaSortOrder
    FROM Oee.ufn_OeeUnits();

    -- ---- 3. Per (location, shift) availability ----
    DECLARE @Av TABLE (
        ShiftId BIGINT, LocationId BIGINT, BaseMinutes INT, EffUnplanned DECIMAL(19,6),
        Availability DECIMAL(5,4), DowntimeEventCount INT, PRIMARY KEY (ShiftId, LocationId));
    INSERT INTO @Av
    SELECT sh.ShiftId, a.LocationId,
           CASE WHEN a.Availability IS NULL THEN 0 ELSE a.BaseMinutes END,
           CASE WHEN a.Availability IS NULL THEN 0
                WHEN a.IsRollup = 1 THEN a.BaseMinutes * (1 - CAST(a.Availability AS DECIMAL(19,6)))
                WHEN a.UnplannedDowntimeMinutes > a.BaseMinutes THEN a.BaseMinutes
                ELSE a.UnplannedDowntimeMinutes END,
           a.Availability, a.DowntimeEventCount
    FROM @Sh sh
    CROSS APPLY Oee.ufn_ShiftAvailability(sh.ShiftId) a;

    -- ---- 4. Good, scrap, downtime events ----
    DECLARE @G TABLE (ShiftId BIGINT, UnitLocationId BIGINT, PlacementIsArea BIT, AreaFamily NVARCHAR(10),
                      ToolId BIGINT, LastEventAt DATETIME2(3), Good BIGINT);
    INSERT INTO @G
    SELECT sh.ShiftId, g.UnitLocationId, g.PlacementIsArea, g.AreaFamily, g.ToolId, g.LastEventAt, g.Good
    FROM @Sh sh CROSS APPLY Oee.ufn_ShiftGood(sh.ShiftId) g;

    DECLARE @S TABLE (ShiftId BIGINT, ChargeFamily NVARCHAR(10), UnitLocationId BIGINT, PlacementIsArea BIT,
                      FoundAtLocationId BIGINT, Quantity BIGINT, IsNonReject BIT, IsFoundDownstream BIT);
    INSERT INTO @S
    SELECT sh.ShiftId, s.ChargeFamily, s.UnitLocationId, s.PlacementIsArea, s.FoundAtLocationId,
           s.Quantity, s.IsNonReject, s.IsFoundDownstream
    FROM @Sh sh CROSS APPLY Oee.ufn_ShiftScrap(sh.ShiftId) s;

    -- Entered downtime, placed on its top unit (or area), plus the exact
    -- location for station rows.
    DECLARE @D TABLE (ShiftId BIGINT, LocationId BIGINT, PlacementLocationId BIGINT, AreaFamily NVARCHAR(10),
                      Minutes DECIMAL(12,2), IsPlanned BIT, IsNoReason BIT);
    INSERT INTO @D
    SELECT de.ShiftId, de.LocationId, af.PlacementLocationId, af.AreaFamily,
           CAST(DATEDIFF(SECOND, de.StartedAt, ISNULL(de.EndedAt, @Now)) / 60.0 AS DECIMAL(12,2)),
           CAST(ISNULL(rc.IsExcused, 0) AS BIT),
           CAST(CASE WHEN de.DowntimeReasonCodeId IS NULL THEN 1 ELSE 0 END AS BIT)
    FROM @Sh sh
    INNER JOIN Oee.DowntimeEvent de ON de.ShiftId = sh.ShiftId AND de.VoidedAt IS NULL
    LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
    CROSS APPLY Oee.ufn_AreaFamily(de.LocationId) af;

    -- ---- 5. Active (unit, shift) pairs ----
    DECLARE @Act TABLE (LocationId BIGINT, ShiftId BIGINT, PRIMARY KEY (LocationId, ShiftId));
    INSERT INTO @Act (LocationId, ShiftId)
    SELECT DISTINCT u.LocationId, sh.ShiftId
    FROM @U u CROSS JOIN @Sh sh
    WHERE u.IsStation = 0
      AND (   EXISTS (SELECT 1 FROM @G g WHERE g.ShiftId = sh.ShiftId AND g.UnitLocationId = u.LocationId AND g.PlacementIsArea = 0)
           OR EXISTS (SELECT 1 FROM @S s WHERE s.ShiftId = sh.ShiftId AND s.FoundAtLocationId = u.LocationId)
           OR EXISTS (SELECT 1 FROM @D d WHERE d.ShiftId = sh.ShiftId AND d.PlacementLocationId = u.LocationId)
           OR EXISTS (SELECT 1 FROM @Av a INNER JOIN @U st ON st.LocationId = a.LocationId
                      WHERE a.ShiftId = sh.ShiftId AND st.TopUnitLocationId = u.LocationId AND a.DowntimeEventCount > 0)
           -- a trim press is active when its shop made or scrapped anything
           OR (u.AreaFamily = N'trim' AND (
                  EXISTS (SELECT 1 FROM @G g WHERE g.ShiftId = sh.ShiftId AND g.UnitLocationId = u.ProductionAreaId AND g.PlacementIsArea = 1)
               OR EXISTS (SELECT 1 FROM @S s WHERE s.ShiftId = sh.ShiftId AND s.FoundAtLocationId = u.ProductionAreaId))));

    -- ---- 6. Rows ----
    DECLARE @R TABLE (
        RowKind NVARCHAR(10), AreaFamily NVARCHAR(10), ProductionAreaId BIGINT, ProductionAreaName NVARCHAR(200),
        LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200), ParentLocationId BIGINT,
        BaseMinutes INT, EffectiveUnplannedMinutes DECIMAL(12,2),
        DowntimeMinutes DECIMAL(12,2), PlannedDowntimeMinutes DECIMAL(12,2), UnplannedDowntimeMinutes DECIMAL(12,2),
        Availability DECIMAL(5,4), Good BIGINT, Scrap BIGINT, NonRejectScrap BIGINT,
        FoundDownstreamScrap BIGINT, UnplacedScrap BIGINT, Quality DECIMAL(5,4),
        NoReasonCount INT, NoReasonMinutes DECIMAL(12,2), LastToolCode NVARCHAR(50),
        HasProduction BIT, SortFamily INT, SortArea INT, SortUnit INT, SortKind INT);

    -- Unit rows
    INSERT INTO @R
    SELECT N'Unit', u.AreaFamily, u.ProductionAreaId, u.ProductionAreaName,
           u.LocationId, u.Code, u.Name, NULL,
           av.Base, av.Eff,
           dt.Total, dt.Planned, dt.Unplanned,
           CASE WHEN av.Base > 0 THEN CAST((av.Base - av.Eff) / av.Base AS DECIMAL(5,4)) END,
           CASE WHEN u.AreaFamily = N'trim' THEN NULL ELSE ISNULL(gd.Good, 0) END,
           CASE WHEN u.AreaFamily = N'trim' THEN NULL ELSE ISNULL(sc.Scrap, 0) END,
           ISNULL(sc.NonReject, 0), NULL, NULL,
           CASE WHEN u.AreaFamily <> N'trim' AND ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0) > 0
                THEN CAST(CAST(ISNULL(gd.Good, 0) AS DECIMAL(19,6)) / (ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0)) AS DECIMAL(5,4)) END,
           ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0),
           tl.Code,
           CASE WHEN EXISTS (SELECT 1 FROM @Act a WHERE a.LocationId = u.LocationId) THEN 1 ELSE 0 END,
           CASE u.AreaFamily WHEN N'diecast' THEN 1 WHEN N'trim' THEN 2 ELSE 3 END,
           u.ProductionAreaSortOrder, u.SortOrder, 4
    FROM @U u
    OUTER APPLY (
        SELECT SUM(CAST(a.BaseMinutes AS INT)) AS Base, CAST(SUM(a.EffUnplanned) AS DECIMAL(19,6)) AS Eff
        FROM @Av a INNER JOIN @Act ac ON ac.LocationId = a.LocationId AND ac.ShiftId = a.ShiftId
        WHERE a.LocationId = u.LocationId
    ) av
    OUTER APPLY (
        SELECT SUM(d.Minutes) AS Total,
               SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END) AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.PlacementLocationId = u.LocationId
    ) dt
    OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.UnitLocationId = u.LocationId AND g.PlacementIsArea = 0) gd
    OUTER APPLY (
        SELECT SUM(s.Quantity) AS Scrap FROM @S s
        WHERE s.IsNonReject = 0 AND s.UnitLocationId = u.LocationId AND s.PlacementIsArea = 0
    ) scu
    OUTER APPLY (
        SELECT SUM(s.Quantity) AS NonReject FROM @S s
        WHERE s.IsNonReject = 1 AND s.FoundAtLocationId = u.LocationId
    ) nru
    CROSS APPLY (SELECT scu.Scrap, nru.NonReject) sc
    OUTER APPLY (
        SELECT TOP 1 t.Code FROM @G g INNER JOIN Tools.Tool t ON t.Id = g.ToolId
        WHERE g.UnitLocationId = u.LocationId ORDER BY g.LastEventAt DESC
    ) tl
    WHERE u.IsStation = 0
      AND EXISTS (SELECT 1 FROM @Sh);

    -- Station rows: availability over the parent unit's active shifts
    INSERT INTO @R
    SELECT N'Station', u.AreaFamily, u.ProductionAreaId, u.ProductionAreaName,
           u.LocationId, u.Code, u.Name, u.ParentUnitLocationId,
           av.Base, av.Eff,
           dt.Total, dt.Planned, dt.Unplanned,
           CASE WHEN av.Base > 0 THEN CAST((av.Base - av.Eff) / av.Base AS DECIMAL(5,4)) END,
           NULL, NULL, NULL, NULL, NULL, NULL,
           ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0), NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @Act a WHERE a.LocationId = u.TopUnitLocationId) THEN 1 ELSE 0 END,
           CASE u.AreaFamily WHEN N'diecast' THEN 1 WHEN N'trim' THEN 2 ELSE 3 END,
           u.ProductionAreaSortOrder, u.SortOrder, 5
    FROM @U u
    OUTER APPLY (
        SELECT SUM(a.BaseMinutes) AS Base, CAST(SUM(a.EffUnplanned) AS DECIMAL(19,6)) AS Eff
        FROM @Av a INNER JOIN @Act ac ON ac.LocationId = u.TopUnitLocationId AND ac.ShiftId = a.ShiftId
        WHERE a.LocationId = u.LocationId
    ) av
    OUTER APPLY (
        SELECT SUM(d.Minutes) AS Total,
               SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END) AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.LocationId = u.LocationId
    ) dt
    WHERE u.IsStation = 1
      AND EXISTS (SELECT 1 FROM @Sh);

    -- Group rows (per ProductionArea): pooled over its units; good + scrap of
    -- its units AND anything booked on the area itself (the trim shop).
    INSERT INTO @R
    SELECT N'Group', grp.AreaFamily, grp.ProductionAreaId, grp.ProductionAreaName,
           grp.ProductionAreaId, NULL, grp.ProductionAreaName, NULL,
           av.Base, av.Eff, dt.Total, dt.Planned, dt.Unplanned,
           CASE WHEN av.Base > 0 THEN CAST((av.Base - av.Eff) / av.Base AS DECIMAL(5,4)) END,
           ISNULL(gd.Good, 0), ISNULL(sc.Scrap, 0), ISNULL(sc.NonReject, 0), NULL, NULL,
           CASE WHEN ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0) > 0
                THEN CAST(CAST(ISNULL(gd.Good, 0) AS DECIMAL(19,6)) / (ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0)) AS DECIMAL(5,4)) END,
           ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0), NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @Act a INNER JOIN @U u ON u.LocationId = a.LocationId
                             WHERE u.ProductionAreaId = grp.ProductionAreaId) THEN 1 ELSE 0 END,
           CASE grp.AreaFamily WHEN N'diecast' THEN 1 WHEN N'trim' THEN 2 ELSE 3 END,
           grp.ProductionAreaSortOrder, 0, 3
    FROM (SELECT DISTINCT ProductionAreaId, ProductionAreaName, ProductionAreaSortOrder, AreaFamily
          FROM @U WHERE IsStation = 0 AND ProductionAreaId IS NOT NULL) grp
    OUTER APPLY (
        SELECT SUM(a.BaseMinutes) AS Base, CAST(SUM(a.EffUnplanned) AS DECIMAL(19,6)) AS Eff
        FROM @Av a
        INNER JOIN @Act ac ON ac.LocationId = a.LocationId AND ac.ShiftId = a.ShiftId
        INNER JOIN @U u    ON u.LocationId = a.LocationId
        WHERE u.ProductionAreaId = grp.ProductionAreaId AND u.IsStation = 0
    ) av
    OUTER APPLY (
        SELECT SUM(d.Minutes) AS Total,
               SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END) AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d
        WHERE d.PlacementLocationId = grp.ProductionAreaId
           OR d.PlacementLocationId IN (SELECT u.LocationId FROM @U u WHERE u.ProductionAreaId = grp.ProductionAreaId AND u.IsStation = 0)
    ) dt
    OUTER APPLY (
        SELECT SUM(g.Good) AS Good FROM @G g
        WHERE (g.PlacementIsArea = 1 AND g.UnitLocationId = grp.ProductionAreaId)
           OR (g.PlacementIsArea = 0 AND g.UnitLocationId IN (SELECT u.LocationId FROM @U u WHERE u.ProductionAreaId = grp.ProductionAreaId AND u.IsStation = 0))
    ) gd
    OUTER APPLY (
        SELECT SUM(CASE WHEN s.IsNonReject = 0 AND s.UnitLocationId IS NOT NULL THEN s.Quantity ELSE 0 END) AS Scrap,
               SUM(CASE WHEN s.IsNonReject = 1 THEN s.Quantity ELSE 0 END) AS NonReject
        FROM @S s
        WHERE s.UnitLocationId = grp.ProductionAreaId
           OR s.UnitLocationId IN (SELECT u.LocationId FROM @U u WHERE u.ProductionAreaId = grp.ProductionAreaId AND u.IsStation = 0)
           OR (s.IsNonReject = 1 AND (s.FoundAtLocationId = grp.ProductionAreaId
               OR s.FoundAtLocationId IN (SELECT u.LocationId FROM @U u WHERE u.ProductionAreaId = grp.ProductionAreaId AND u.IsStation = 0)))
    ) sc
    WHERE EXISTS (SELECT 1 FROM @Sh);

    -- Area rows (per family): everything charged to the family
    INSERT INTO @R
    SELECT N'Area', f.AreaFamily, NULL, NULL, NULL, NULL,
           CASE f.AreaFamily WHEN N'diecast' THEN N'Die Cast' WHEN N'trim' THEN N'Trim' ELSE N'Machining & Assembly' END, NULL,
           av.Base, av.Eff, dt.Total, dt.Planned, dt.Unplanned,
           CASE WHEN av.Base > 0 THEN CAST((av.Base - av.Eff) / av.Base AS DECIMAL(5,4)) END,
           ISNULL(gd.Good, 0), ISNULL(sc.Scrap, 0), ISNULL(sc.NonReject, 0), ISNULL(sc.Downstream, 0), NULL,
           CASE WHEN ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0) > 0
                THEN CAST(CAST(ISNULL(gd.Good, 0) AS DECIMAL(19,6)) / (ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0)) AS DECIMAL(5,4)) END,
           ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0), NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @Act a INNER JOIN @U u ON u.LocationId = a.LocationId
                             WHERE u.AreaFamily = f.AreaFamily) THEN 1 ELSE 0 END,
           f.SortFamily, 0, 0, 2
    FROM (VALUES (N'diecast', 1), (N'trim', 2), (N'ma', 3)) f (AreaFamily, SortFamily)
    OUTER APPLY (
        SELECT SUM(a.BaseMinutes) AS Base, CAST(SUM(a.EffUnplanned) AS DECIMAL(19,6)) AS Eff
        FROM @Av a
        INNER JOIN @Act ac ON ac.LocationId = a.LocationId AND ac.ShiftId = a.ShiftId
        INNER JOIN @U u    ON u.LocationId = a.LocationId
        WHERE u.AreaFamily = f.AreaFamily AND u.IsStation = 0
    ) av
    OUTER APPLY (
        SELECT SUM(d.Minutes) AS Total,
               SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END) AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.AreaFamily = f.AreaFamily
    ) dt
    OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.AreaFamily = f.AreaFamily) gd
    OUTER APPLY (
        SELECT SUM(CASE WHEN s.IsNonReject = 0 THEN s.Quantity ELSE 0 END) AS Scrap,
               SUM(CASE WHEN s.IsNonReject = 1 THEN s.Quantity ELSE 0 END) AS NonReject,
               SUM(CASE WHEN s.IsNonReject = 0 AND s.IsFoundDownstream = 1 THEN s.Quantity ELSE 0 END) AS Downstream
        FROM @S s WHERE s.ChargeFamily = f.AreaFamily
    ) sc
    WHERE EXISTS (SELECT 1 FROM @Sh);

    -- Plant row
    INSERT INTO @R
    SELECT N'Plant', NULL, NULL, NULL, NULL, NULL, N'Plant', NULL,
           av.Base, av.Eff, dt.Total, dt.Planned, dt.Unplanned,
           CASE WHEN av.Base > 0 THEN CAST((av.Base - av.Eff) / av.Base AS DECIMAL(5,4)) END,
           ISNULL(gd.Good, 0), ISNULL(sc.Scrap, 0), ISNULL(sc.NonReject, 0), ISNULL(sc.Downstream, 0), ISNULL(sc.Unplaced, 0),
           CASE WHEN ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0) > 0
                THEN CAST(CAST(ISNULL(gd.Good, 0) AS DECIMAL(19,6)) / (ISNULL(gd.Good, 0) + ISNULL(sc.Scrap, 0)) AS DECIMAL(5,4)) END,
           ISNULL(dt.NoReasonCount, 0), ISNULL(dt.NoReasonMinutes, 0), NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @Act) THEN 1 ELSE 0 END,
           0, 0, 0, 1
    FROM (SELECT 1 AS One) one
    OUTER APPLY (
        SELECT SUM(a.BaseMinutes) AS Base, CAST(SUM(a.EffUnplanned) AS DECIMAL(19,6)) AS Eff
        FROM @Av a
        INNER JOIN @Act ac ON ac.LocationId = a.LocationId AND ac.ShiftId = a.ShiftId
    ) av
    OUTER APPLY (
        SELECT SUM(d.Minutes) AS Total,
               SUM(CASE WHEN d.IsPlanned = 1 THEN d.Minutes ELSE 0 END) AS Planned,
               SUM(CASE WHEN d.IsPlanned = 0 THEN d.Minutes ELSE 0 END) AS Unplanned,
               SUM(CASE WHEN d.IsNoReason = 1 THEN 1 ELSE 0 END) AS NoReasonCount,
               SUM(CASE WHEN d.IsNoReason = 1 THEN d.Minutes ELSE 0 END) AS NoReasonMinutes
        FROM @D d WHERE d.AreaFamily IS NOT NULL
    ) dt
    OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.AreaFamily IS NOT NULL) gd
    OUTER APPLY (
        SELECT SUM(CASE WHEN s.IsNonReject = 0 AND s.ChargeFamily IS NOT NULL THEN s.Quantity ELSE 0 END) AS Scrap,
               SUM(CASE WHEN s.IsNonReject = 1 THEN s.Quantity ELSE 0 END) AS NonReject,
               SUM(CASE WHEN s.IsNonReject = 0 AND s.IsFoundDownstream = 1 THEN s.Quantity ELSE 0 END) AS Downstream,
               SUM(CASE WHEN s.IsNonReject = 0 AND s.ChargeFamily IS NULL THEN s.Quantity ELSE 0 END) AS Unplaced
        FROM @S s
    ) sc
    WHERE EXISTS (SELECT 1 FROM @Sh);

    -- ---- 7. Result ----
    SELECT
        r.RowKind, r.AreaFamily, r.ProductionAreaId, r.ProductionAreaName,
        r.LocationId, r.LocationCode, r.LocationName, r.ParentLocationId,
        ISNULL(r.BaseMinutes, 0) AS BaseMinutes,
        CAST(ISNULL(r.EffectiveUnplannedMinutes, 0) AS DECIMAL(12,2)) AS EffectiveUnplannedMinutes,
        ISNULL(r.DowntimeMinutes, 0) AS DowntimeMinutes,
        ISNULL(r.PlannedDowntimeMinutes, 0) AS PlannedDowntimeMinutes,
        ISNULL(r.UnplannedDowntimeMinutes, 0) AS UnplannedDowntimeMinutes,
        r.Availability, ab.Band AS AvailabilityBand,
        r.Good, r.Scrap, r.NonRejectScrap, r.FoundDownstreamScrap, r.UnplacedScrap,
        r.Quality, qb.Band AS QualityBand,
        r.NoReasonCount, r.NoReasonMinutes, r.LastToolCode,
        r.HasProduction, @InProgress AS IncludesInProgressShift,
        ROW_NUMBER() OVER (ORDER BY r.SortFamily, r.SortKind, r.SortArea, r.ProductionAreaName, r.SortUnit, r.LocationName) AS SortKey
    FROM @R r
    OUTER APPLY Oee.ufn_OeeBand(r.Availability) ab
    OUTER APPLY Oee.ufn_OeeBand(r.Quality) qb
    WHERE r.RowKind = N'Plant' OR @AreaFamily IS NULL OR r.AreaFamily = @AreaFamily
    ORDER BY SortKey;
END
GO
