-- =============================================
-- Procedure:   Oee.Dashboard_GetBreakdown
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   The unit drill-down's breakdown table (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 5.4):
--     Day zoom   one row per shift of the production day, in day order
--                (3rd -> 1st -> 2nd, Oee.ufn_ShiftsForPeriod's SortKey);
--                a tap zooms to that shift
--     Week zoom  seven rows, Monday to Sunday; a tap zooms to that day
--                (anchored on its latest shift; NULL for a day with no shifts)
--     Shift zoom no rows (the page shows the downtime entries instead)
--   Pooled per row over the scope (Oee.ufn_ScopeMeasures): @LocationId, or the
--   plant when NULL.
--
-- Result set: ChildZoom, ChildAnchorShiftId, Label, BaseMinutes,
--   DowntimeMinutes, Availability, Good, Scrap, Quality, AvailabilityBand,
--   QualityBand.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetBreakdown
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT,
    @LocationId    BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @R TABLE (SortKey INT, ChildZoom NVARCHAR(5), ChildAnchorShiftId BIGINT, Label NVARCHAR(60),
                      Base INT, Eff DECIMAL(19,6), Downtime DECIMAL(12,2), Good BIGINT, Scrap BIGINT);

    IF @Zoom = N'Day'
        INSERT INTO @R
        SELECT p.SortKey, N'Shift', p.ShiftId, ss.Name,
               m.BaseMinutes, m.EffectiveUnplannedMinutes, m.DowntimeMinutes, m.Good, m.Scrap
        FROM Oee.ufn_ShiftsForPeriod(N'Day', @AnchorShiftId) p
        INNER JOIN Oee.Shift s          ON s.Id = p.ShiftId
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        CROSS APPLY Oee.ufn_ScopeMeasures(p.ShiftId, NULL, @LocationId) m;
    ELSE IF @Zoom = N'Week' AND EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @AnchorShiftId)
    BEGIN
        DECLARE @Day DATE = (SELECT ProductionDay FROM Oee.ufn_ProductionDay(@AnchorShiftId));
        DECLARE @Mon DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @Day) % 7), @Day);

        ;WITH Days AS (
            SELECT n, DATEADD(DAY, n, @Mon) AS ProductionDay FROM (VALUES (0),(1),(2),(3),(4),(5),(6)) v (n)
        ),
        Sh AS (
            SELECT p.ShiftId, p.ProductionDay, s.ActualStart
            FROM Oee.ufn_ShiftsForPeriod(N'Week', @AnchorShiftId) p
            INNER JOIN Oee.Shift s ON s.Id = p.ShiftId
        ),
        M AS (
            SELECT sh.ProductionDay, SUM(m.BaseMinutes) AS Base, SUM(m.EffectiveUnplannedMinutes) AS Eff,
                   SUM(m.DowntimeMinutes) AS Downtime, SUM(m.Good) AS Good, SUM(m.Scrap) AS Scrap
            FROM Sh sh CROSS APPLY Oee.ufn_ScopeMeasures(sh.ShiftId, NULL, @LocationId) m
            GROUP BY sh.ProductionDay
        )
        INSERT INTO @R
        SELECT d.n, N'Day',
               (SELECT TOP 1 sh.ShiftId FROM Sh sh WHERE sh.ProductionDay = d.ProductionDay ORDER BY sh.ActualStart DESC),
               LEFT(DATENAME(WEEKDAY, d.ProductionDay), 3) + N' ' + CAST(MONTH(d.ProductionDay) AS NVARCHAR(2))
                   + N'/' + CAST(DAY(d.ProductionDay) AS NVARCHAR(2)),
               ISNULL(M.Base, 0), ISNULL(M.Eff, 0), ISNULL(M.Downtime, 0), ISNULL(M.Good, 0), ISNULL(M.Scrap, 0)
        FROM Days d LEFT JOIN M ON M.ProductionDay = d.ProductionDay;
    END

    SELECT r.ChildZoom, r.ChildAnchorShiftId, r.Label,
           r.Base AS BaseMinutes, r.Downtime AS DowntimeMinutes, x.Availability,
           r.Good, r.Scrap, x.Quality, ab.Band AS AvailabilityBand, qb.Band AS QualityBand
    FROM @R r
    CROSS APPLY (
        SELECT CASE WHEN r.Base > 0 THEN CAST((r.Base - r.Eff) / r.Base AS DECIMAL(5,4)) END AS Availability,
               CASE WHEN r.Good + r.Scrap > 0 THEN CAST(CAST(r.Good AS DECIMAL(19,6)) / (r.Good + r.Scrap) AS DECIMAL(5,4)) END AS Quality
    ) x
    OUTER APPLY Oee.ufn_OeeBand(x.Availability) ab
    OUTER APPLY Oee.ufn_OeeBand(x.Quality) qb
    ORDER BY r.SortKey;
END
GO
