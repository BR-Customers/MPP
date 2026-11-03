-- =============================================
-- Repeatable:  R__Oee_ufn_zzzzzz_ScopeMeasures.sql
-- Object:      Oee.ufn_ScopeMeasures
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   One shift's poolable minutes and counts for ONE scope (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 6.3):
--     @LocationId  a unit, a station or an area placement (the trim shop)
--     @AreaFamily  a family (diecast | trim | ma), when @LocationId is NULL
--     both NULL    the plant
--   The trend and the breakdown sum these over their days / shifts and pool
--   (never average). Same rules as Dashboard_GetUnitSummary's Unit / Station /
--   Area / Plant rows:
--     availability  BaseMinutes / EffectiveUnplannedMinutes of ACTIVE rows
--     downtime      entered minutes (planned + unplanned)
--     good          unit (+ area placement) good
--     scrap         a location: what landed on it; a family / the plant:
--                   everything charged to it (AreaCharge)
--   Reads Oee.ufn_PeriodSummaryRows, so a stored shift is read, not recomputed.
--
--   Inline TVF, one row. FILE NAME IS ORDER-SENSITIVE -- 'zzzzzz_' sorts after
--   ufn_zzzzz_PeriodSummaryRows, which it calls.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ScopeMeasures (@ShiftId BIGINT, @AreaFamily NVARCHAR(10), @LocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        ISNULL(SUM(CASE WHEN r.IsActive = 1
                         AND (   (@LocationId IS NOT NULL AND r.LocationId = @LocationId AND r.RowKind IN (N'Unit', N'Station'))
                              OR (@LocationId IS NULL AND r.RowKind = N'Unit' AND (@AreaFamily IS NULL OR r.AreaFamily = @AreaFamily)))
                        THEN r.BaseMinutes ELSE 0 END), 0) AS BaseMinutes,
        CAST(ISNULL(SUM(CASE WHEN r.IsActive = 1
                         AND (   (@LocationId IS NOT NULL AND r.LocationId = @LocationId AND r.RowKind IN (N'Unit', N'Station'))
                              OR (@LocationId IS NULL AND r.RowKind = N'Unit' AND (@AreaFamily IS NULL OR r.AreaFamily = @AreaFamily)))
                        THEN r.EffectiveUnplannedMinutes ELSE 0 END), 0) AS DECIMAL(19,6)) AS EffectiveUnplannedMinutes,
        CAST(ISNULL(SUM(CASE WHEN (@LocationId IS NOT NULL AND r.LocationId = @LocationId AND r.RowKind IN (N'Unit', N'Station', N'AreaPlacement'))
                              OR (@LocationId IS NULL AND r.RowKind IN (N'Unit', N'AreaPlacement')
                                  AND ((@AreaFamily IS NULL AND r.AreaFamily IS NOT NULL) OR r.AreaFamily = @AreaFamily))
                        THEN r.PlannedDowntimeMinutes + r.UnplannedDowntimeMinutes ELSE 0 END), 0) AS DECIMAL(12,2)) AS DowntimeMinutes,
        ISNULL(SUM(CASE WHEN (@LocationId IS NOT NULL AND r.LocationId = @LocationId AND r.RowKind IN (N'Unit', N'AreaPlacement'))
                          OR (@LocationId IS NULL AND r.RowKind IN (N'Unit', N'AreaPlacement')
                              AND ((@AreaFamily IS NULL AND r.AreaFamily IS NOT NULL) OR r.AreaFamily = @AreaFamily))
                        THEN r.Good ELSE 0 END), 0) AS Good,
        ISNULL(SUM(CASE WHEN (@LocationId IS NOT NULL AND r.LocationId = @LocationId AND r.RowKind IN (N'Unit', N'AreaPlacement'))
                          OR (@LocationId IS NULL AND r.RowKind = N'AreaCharge'
                              AND ((@AreaFamily IS NULL AND r.AreaFamily IS NOT NULL) OR r.AreaFamily = @AreaFamily))
                        THEN r.Scrap ELSE 0 END), 0) AS Scrap
    FROM Oee.ufn_PeriodSummaryRows(N'Shift', @ShiftId) r
);
GO
