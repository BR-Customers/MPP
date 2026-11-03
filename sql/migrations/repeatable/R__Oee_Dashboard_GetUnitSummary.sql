-- =============================================
-- Procedure:   Oee.Dashboard_GetUnitSummary
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     2.0
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
--   v2.0 (spec v0.3.2 sec 6.7, G7): every figure is POOLED FROM STORED
--   per-shift rows (Oee.ShiftSummary) -- a read never recomputes history. The
--   shift in progress, and a closed shift not stored yet, come from the same
--   calculation live (Oee.ufn_PeriodSummaryRows decides which). Row meanings:
--   Oee.ufn_ShiftSummaryRows' header.
--
--   Downtime MINUTES (DowntimeMinutes / Planned / Unplanned / NoReason) are the
--   entered durations placed on the row -- the Pareto's basis. Availability
--   pools BaseMinutes / EffectiveUnplannedMinutes of the active rows. An entry
--   with no reason counts as unplanned.
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
--   2026-10-30 - 2.0 - Pools stored per-shift rows (Oee.ufn_PeriodSummaryRows) instead of
--                      recomputing every shift on every read. Columns unchanged.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetUnitSummary
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT,
    @AreaFamily    NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    -- ---- 1. The period's per-shift rows (stored, or live for unstored shifts) ----
    DECLARE @P TABLE (
        ShiftId BIGINT, LocationId BIGINT, RowKind NVARCHAR(15), AreaFamily NVARCHAR(10),
        ProductionAreaId BIGINT, ParentUnitLocationId BIGINT,
        PlannedDowntimeMinutes DECIMAL(12,2), UnplannedDowntimeMinutes DECIMAL(12,2),
        BaseMinutes INT, EffectiveUnplannedMinutes DECIMAL(12,4),
        NoReasonCount INT, NoReasonMinutes DECIMAL(12,2),
        Good BIGINT, Scrap BIGINT, NonRejectScrap BIGINT, FoundDownstreamScrap BIGINT, UnplacedScrap BIGINT,
        LastToolId BIGINT, IsActive BIT, ShiftActualStart DATETIME2(3), IsOpen BIT);
    INSERT INTO @P
    SELECT ShiftId, LocationId, RowKind, AreaFamily, ProductionAreaId, ParentUnitLocationId,
           PlannedDowntimeMinutes, UnplannedDowntimeMinutes, BaseMinutes, EffectiveUnplannedMinutes,
           NoReasonCount, NoReasonMinutes, Good, Scrap, NonRejectScrap, FoundDownstreamScrap, UnplacedScrap,
           LastToolId, IsActive, ShiftActualStart, IsOpen
    FROM Oee.ufn_PeriodSummaryRows(@Zoom, @AnchorShiftId);

    DECLARE @HasShifts BIT = CASE WHEN EXISTS (SELECT 1 FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId)) THEN 1 ELSE 0 END;
    DECLARE @InProgress BIT = CASE WHEN EXISTS (SELECT 1 FROM @P WHERE IsOpen = 1) THEN 1 ELSE 0 END;

    -- ---- 2. Units (names, sort) ----
    DECLARE @U TABLE (
        LocationId BIGINT PRIMARY KEY, Code NVARCHAR(50), Name NVARCHAR(200),
        SortOrder INT, IsStation BIT, ParentUnitLocationId BIGINT,
        AreaFamily NVARCHAR(10), ProductionAreaId BIGINT, ProductionAreaName NVARCHAR(200), ProductionAreaSortOrder INT);
    INSERT INTO @U
    SELECT LocationId, Code, Name, SortOrder, IsStation, ParentUnitLocationId,
           AreaFamily, ProductionAreaId, ProductionAreaName, ProductionAreaSortOrder
    FROM Oee.ufn_OeeUnits();

    -- ---- 3. Rows ----
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
           a.Base, a.Eff, a.Planned + a.Unplanned, a.Planned, a.Unplanned,
           CASE WHEN a.Base > 0 THEN CAST((a.Base - a.Eff) / a.Base AS DECIMAL(5,4)) END,
           CASE WHEN u.AreaFamily = N'trim' THEN NULL ELSE a.Good END,
           CASE WHEN u.AreaFamily = N'trim' THEN NULL ELSE a.Scrap END,
           a.NonReject, NULL, NULL,
           CASE WHEN u.AreaFamily <> N'trim' AND a.Good + a.Scrap > 0
                THEN CAST(CAST(a.Good AS DECIMAL(19,6)) / (a.Good + a.Scrap) AS DECIMAL(5,4)) END,
           a.NoReasonCount, a.NoReasonMinutes, tl.Code, a.Active,
           CASE u.AreaFamily WHEN N'diecast' THEN 1 WHEN N'trim' THEN 2 ELSE 3 END,
           u.ProductionAreaSortOrder, u.SortOrder, 4
    FROM @U u
    CROSS APPLY (
        SELECT ISNULL(SUM(CASE WHEN p.IsActive = 1 THEN p.BaseMinutes ELSE 0 END), 0)                AS Base,
               CAST(ISNULL(SUM(CASE WHEN p.IsActive = 1 THEN p.EffectiveUnplannedMinutes ELSE 0 END), 0) AS DECIMAL(19,6)) AS Eff,
               ISNULL(SUM(p.PlannedDowntimeMinutes), 0)   AS Planned,
               ISNULL(SUM(p.UnplannedDowntimeMinutes), 0) AS Unplanned,
               ISNULL(SUM(p.Good), 0)                     AS Good,
               ISNULL(SUM(p.Scrap), 0)                    AS Scrap,
               ISNULL(SUM(p.NonRejectScrap), 0)           AS NonReject,
               ISNULL(SUM(p.NoReasonCount), 0)            AS NoReasonCount,
               ISNULL(SUM(p.NoReasonMinutes), 0)          AS NoReasonMinutes,
               CAST(ISNULL(MAX(CAST(p.IsActive AS INT)), 0) AS BIT) AS Active
        FROM @P p WHERE p.RowKind = N'Unit' AND p.LocationId = u.LocationId
    ) a
    OUTER APPLY (
        SELECT TOP 1 t.Code FROM @P p INNER JOIN Tools.Tool t ON t.Id = p.LastToolId
        WHERE p.RowKind = N'Unit' AND p.LocationId = u.LocationId
        ORDER BY p.ShiftActualStart DESC
    ) tl
    WHERE u.IsStation = 0 AND @HasShifts = 1;

    -- Station rows: availability over the parent unit's active shifts
    INSERT INTO @R
    SELECT N'Station', u.AreaFamily, u.ProductionAreaId, u.ProductionAreaName,
           u.LocationId, u.Code, u.Name, u.ParentUnitLocationId,
           a.Base, a.Eff, a.Planned + a.Unplanned, a.Planned, a.Unplanned,
           CASE WHEN a.Base > 0 THEN CAST((a.Base - a.Eff) / a.Base AS DECIMAL(5,4)) END,
           NULL, NULL, NULL, NULL, NULL, NULL,
           a.NoReasonCount, a.NoReasonMinutes, NULL, a.Active,
           CASE u.AreaFamily WHEN N'diecast' THEN 1 WHEN N'trim' THEN 2 ELSE 3 END,
           u.ProductionAreaSortOrder, u.SortOrder, 5
    FROM @U u
    CROSS APPLY (
        SELECT ISNULL(SUM(CASE WHEN p.IsActive = 1 THEN p.BaseMinutes ELSE 0 END), 0)                AS Base,
               CAST(ISNULL(SUM(CASE WHEN p.IsActive = 1 THEN p.EffectiveUnplannedMinutes ELSE 0 END), 0) AS DECIMAL(19,6)) AS Eff,
               ISNULL(SUM(p.PlannedDowntimeMinutes), 0)   AS Planned,
               ISNULL(SUM(p.UnplannedDowntimeMinutes), 0) AS Unplanned,
               ISNULL(SUM(p.NoReasonCount), 0)            AS NoReasonCount,
               ISNULL(SUM(p.NoReasonMinutes), 0)          AS NoReasonMinutes,
               CAST(ISNULL(MAX(CAST(p.IsActive AS INT)), 0) AS BIT) AS Active
        FROM @P p WHERE p.RowKind = N'Station' AND p.LocationId = u.LocationId
    ) a
    WHERE u.IsStation = 1 AND @HasShifts = 1;

    -- Group rows (per ProductionArea): its units' rows + anything booked on the area itself
    INSERT INTO @R
    SELECT N'Group', grp.AreaFamily, grp.ProductionAreaId, grp.ProductionAreaName,
           grp.ProductionAreaId, NULL, grp.ProductionAreaName, NULL,
           a.Base, a.Eff, a.Planned + a.Unplanned, a.Planned, a.Unplanned,
           CASE WHEN a.Base > 0 THEN CAST((a.Base - a.Eff) / a.Base AS DECIMAL(5,4)) END,
           a.Good, a.Scrap, a.NonReject, NULL, NULL,
           CASE WHEN a.Good + a.Scrap > 0 THEN CAST(CAST(a.Good AS DECIMAL(19,6)) / (a.Good + a.Scrap) AS DECIMAL(5,4)) END,
           a.NoReasonCount, a.NoReasonMinutes, NULL, a.Active,
           CASE grp.AreaFamily WHEN N'diecast' THEN 1 WHEN N'trim' THEN 2 ELSE 3 END,
           grp.ProductionAreaSortOrder, 0, 3
    FROM (SELECT DISTINCT ProductionAreaId, ProductionAreaName, ProductionAreaSortOrder, AreaFamily
          FROM @U WHERE IsStation = 0 AND ProductionAreaId IS NOT NULL) grp
    CROSS APPLY (
        SELECT ISNULL(SUM(CASE WHEN p.RowKind = N'Unit' AND p.IsActive = 1 THEN p.BaseMinutes ELSE 0 END), 0) AS Base,
               CAST(ISNULL(SUM(CASE WHEN p.RowKind = N'Unit' AND p.IsActive = 1 THEN p.EffectiveUnplannedMinutes ELSE 0 END), 0) AS DECIMAL(19,6)) AS Eff,
               ISNULL(SUM(p.PlannedDowntimeMinutes), 0)   AS Planned,
               ISNULL(SUM(p.UnplannedDowntimeMinutes), 0) AS Unplanned,
               ISNULL(SUM(p.Good), 0)                     AS Good,
               ISNULL(SUM(p.Scrap), 0)                    AS Scrap,
               ISNULL(SUM(p.NonRejectScrap), 0)           AS NonReject,
               ISNULL(SUM(p.NoReasonCount), 0)            AS NoReasonCount,
               ISNULL(SUM(p.NoReasonMinutes), 0)          AS NoReasonMinutes,
               CAST(ISNULL(MAX(CASE WHEN p.RowKind = N'Unit' THEN CAST(p.IsActive AS INT) ELSE 0 END), 0) AS BIT) AS Active
        FROM @P p
        WHERE (p.RowKind = N'Unit' AND p.LocationId IN (SELECT u.LocationId FROM @U u WHERE u.ProductionAreaId = grp.ProductionAreaId AND u.IsStation = 0))
           OR (p.RowKind = N'AreaPlacement' AND p.LocationId = grp.ProductionAreaId)
    ) a
    WHERE @HasShifts = 1;

    -- Area rows (per family): units + area placements; scrap = everything charged to the family
    INSERT INTO @R
    SELECT N'Area', f.AreaFamily, NULL, NULL, NULL, NULL,
           CASE f.AreaFamily WHEN N'diecast' THEN N'Die Cast' WHEN N'trim' THEN N'Trim' ELSE N'Machining & Assembly' END, NULL,
           a.Base, a.Eff, a.Planned + a.Unplanned, a.Planned, a.Unplanned,
           CASE WHEN a.Base > 0 THEN CAST((a.Base - a.Eff) / a.Base AS DECIMAL(5,4)) END,
           a.Good, c.Scrap, c.NonReject, c.Downstream, NULL,
           CASE WHEN a.Good + c.Scrap > 0 THEN CAST(CAST(a.Good AS DECIMAL(19,6)) / (a.Good + c.Scrap) AS DECIMAL(5,4)) END,
           a.NoReasonCount, a.NoReasonMinutes, NULL, a.Active,
           f.SortFamily, 0, 0, 2
    FROM (VALUES (N'diecast', 1), (N'trim', 2), (N'ma', 3)) f (AreaFamily, SortFamily)
    CROSS APPLY (
        SELECT ISNULL(SUM(CASE WHEN p.RowKind = N'Unit' AND p.IsActive = 1 THEN p.BaseMinutes ELSE 0 END), 0) AS Base,
               CAST(ISNULL(SUM(CASE WHEN p.RowKind = N'Unit' AND p.IsActive = 1 THEN p.EffectiveUnplannedMinutes ELSE 0 END), 0) AS DECIMAL(19,6)) AS Eff,
               ISNULL(SUM(p.PlannedDowntimeMinutes), 0)   AS Planned,
               ISNULL(SUM(p.UnplannedDowntimeMinutes), 0) AS Unplanned,
               ISNULL(SUM(p.Good), 0)                     AS Good,
               ISNULL(SUM(p.NoReasonCount), 0)            AS NoReasonCount,
               ISNULL(SUM(p.NoReasonMinutes), 0)          AS NoReasonMinutes,
               CAST(ISNULL(MAX(CASE WHEN p.RowKind = N'Unit' THEN CAST(p.IsActive AS INT) ELSE 0 END), 0) AS BIT) AS Active
        FROM @P p
        WHERE p.RowKind IN (N'Unit', N'AreaPlacement') AND p.AreaFamily = f.AreaFamily
    ) a
    CROSS APPLY (
        SELECT ISNULL(SUM(p.Scrap), 0) AS Scrap, ISNULL(SUM(p.NonRejectScrap), 0) AS NonReject,
               ISNULL(SUM(p.FoundDownstreamScrap), 0) AS Downstream
        FROM @P p WHERE p.RowKind = N'AreaCharge' AND p.AreaFamily = f.AreaFamily
    ) c
    WHERE @HasShifts = 1;

    -- Plant row
    INSERT INTO @R
    SELECT N'Plant', NULL, NULL, NULL, NULL, NULL, N'Plant', NULL,
           a.Base, a.Eff, a.Planned + a.Unplanned, a.Planned, a.Unplanned,
           CASE WHEN a.Base > 0 THEN CAST((a.Base - a.Eff) / a.Base AS DECIMAL(5,4)) END,
           a.Good, c.Scrap, c.NonReject, c.Downstream, c.Unplaced,
           CASE WHEN a.Good + c.Scrap > 0 THEN CAST(CAST(a.Good AS DECIMAL(19,6)) / (a.Good + c.Scrap) AS DECIMAL(5,4)) END,
           a.NoReasonCount, a.NoReasonMinutes, NULL, a.Active,
           0, 0, 0, 1
    FROM (SELECT 1 AS One) one
    CROSS APPLY (
        SELECT ISNULL(SUM(CASE WHEN p.RowKind = N'Unit' AND p.IsActive = 1 THEN p.BaseMinutes ELSE 0 END), 0) AS Base,
               CAST(ISNULL(SUM(CASE WHEN p.RowKind = N'Unit' AND p.IsActive = 1 THEN p.EffectiveUnplannedMinutes ELSE 0 END), 0) AS DECIMAL(19,6)) AS Eff,
               ISNULL(SUM(p.PlannedDowntimeMinutes), 0)   AS Planned,
               ISNULL(SUM(p.UnplannedDowntimeMinutes), 0) AS Unplanned,
               ISNULL(SUM(p.Good), 0)                     AS Good,
               ISNULL(SUM(p.NoReasonCount), 0)            AS NoReasonCount,
               ISNULL(SUM(p.NoReasonMinutes), 0)          AS NoReasonMinutes,
               CAST(ISNULL(MAX(CASE WHEN p.RowKind = N'Unit' THEN CAST(p.IsActive AS INT) ELSE 0 END), 0) AS BIT) AS Active
        FROM @P p
        WHERE p.RowKind IN (N'Unit', N'AreaPlacement') AND p.AreaFamily IS NOT NULL
    ) a
    CROSS APPLY (
        SELECT ISNULL(SUM(CASE WHEN p.AreaFamily IS NOT NULL THEN p.Scrap ELSE 0 END), 0)   AS Scrap,
               ISNULL(SUM(p.NonRejectScrap), 0)                                       AS NonReject,
               ISNULL(SUM(p.FoundDownstreamScrap), 0)                                 AS Downstream,
               ISNULL(SUM(p.UnplacedScrap), 0)                                        AS Unplaced
        FROM @P p WHERE p.RowKind = N'AreaCharge'
    ) c
    WHERE @HasShifts = 1;

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
