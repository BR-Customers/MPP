-- =============================================
-- Procedure:   Oee.Dashboard_GetTrend
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   The 7-bar availability trend on the site cards (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 5.2):
--   the 7 production days ending at the anchor shift's production day, pooled
--   per day over the scope (Oee.ufn_ScopeMeasures: a unit, a family, or the
--   plant). Always 7 rows, oldest first; a day with no active base shows NULL.
--
-- Parameters: @AnchorShiftId BIGINT, @AreaFamily NVARCHAR(10) = NULL,
--             @LocationId BIGINT = NULL.
-- Result set: ProductionDay, DayLabel ('Mon 3/4'), Availability, Quality,
--             AvailabilityBand, QualityBand. Unknown anchor -> no rows.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetTrend
    @AnchorShiftId BIGINT,
    @AreaFamily    NVARCHAR(10) = NULL,
    @LocationId    BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Day DATE = (SELECT ProductionDay FROM Oee.ufn_ProductionDay(@AnchorShiftId));

    ;WITH Days AS (
        SELECT DATEADD(DAY, -n, @Day) AS ProductionDay
        FROM (VALUES (0),(1),(2),(3),(4),(5),(6)) v (n)
        WHERE @Day IS NOT NULL
    ),
    M AS (
        SELECT pd.ProductionDay,
               SUM(m.BaseMinutes) AS Base, SUM(m.EffectiveUnplannedMinutes) AS Eff,
               SUM(m.Good) AS Good, SUM(m.Scrap) AS Scrap
        FROM Oee.Shift s
        CROSS APPLY Oee.ufn_ProductionDay(s.Id) pd
        CROSS APPLY Oee.ufn_ScopeMeasures(s.Id, @AreaFamily, @LocationId) m
        WHERE s.ActualStart >= DATEADD(DAY, -8, CAST(@Day AS DATETIME2(3)))
          AND s.ActualStart <  DATEADD(DAY,  1, CAST(@Day AS DATETIME2(3)))
          AND pd.ProductionDay BETWEEN DATEADD(DAY, -6, @Day) AND @Day
        GROUP BY pd.ProductionDay
    )
    SELECT d.ProductionDay,
           CAST(LEFT(DATENAME(WEEKDAY, d.ProductionDay), 3) + N' ' + CAST(MONTH(d.ProductionDay) AS NVARCHAR(2))
                + N'/' + CAST(DAY(d.ProductionDay) AS NVARCHAR(2)) AS NVARCHAR(20)) AS DayLabel,
           x.Availability, x.Quality, ab.Band AS AvailabilityBand, qb.Band AS QualityBand
    FROM Days d
    LEFT JOIN M ON M.ProductionDay = d.ProductionDay
    CROSS APPLY (
        SELECT CASE WHEN M.Base > 0 THEN CAST((M.Base - M.Eff) / M.Base AS DECIMAL(5,4)) END AS Availability,
               CASE WHEN M.Good + M.Scrap > 0 THEN CAST(CAST(M.Good AS DECIMAL(19,6)) / (M.Good + M.Scrap) AS DECIMAL(5,4)) END AS Quality
    ) x
    OUTER APPLY Oee.ufn_OeeBand(x.Availability) ab
    OUTER APPLY Oee.ufn_OeeBand(x.Quality) qb
    ORDER BY d.ProductionDay;
END
GO
