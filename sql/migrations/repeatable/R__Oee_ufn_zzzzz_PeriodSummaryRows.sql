-- =============================================
-- Repeatable:  R__Oee_ufn_zzzzz_PeriodSummaryRows.sql
-- Object:      Oee.ufn_PeriodSummaryRows
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   Every per-shift OEE row of a period (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 6.7):
--     a CLOSED shift with stored rows  -> Oee.ShiftSummary (no recompute -- G7)
--     the shift in progress, or a closed shift not stored yet
--                                      -> Oee.ufn_ShiftSummaryRows, live
--   The one place the stored / live rule lives; every dashboard read that
--   pools minutes and counts reads it.
--
--   Columns: the Oee.ufn_ShiftSummaryRows columns plus ShiftActualStart (for
--   "latest shift" picks) and IsOpen.
--
--   Inline TVF. FILE NAME IS ORDER-SENSITIVE -- 'zzzzz_' sorts after
--   ufn_zzzz_ShiftSummaryRows, which it calls.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_PeriodSummaryRows (@Zoom NVARCHAR(5), @AnchorShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH P AS (
        SELECT p.ShiftId, s.ActualStart,
               CAST(CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
               CAST(CASE WHEN s.ActualEnd IS NOT NULL
                          AND EXISTS (SELECT 1 FROM Oee.ShiftSummary ss WHERE ss.ShiftId = p.ShiftId)
                         THEN 1 ELSE 0 END AS BIT) AS IsStored
        FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
        INNER JOIN Oee.Shift s ON s.Id = p.ShiftId
    )
    SELECT ss.ShiftId, ss.LocationId, ss.RowKind, ss.AreaFamily, ss.ProductionAreaId, ss.ParentUnitLocationId,
           ss.PlannedMinutes, ss.PlannedDowntimeMinutes, ss.UnplannedDowntimeMinutes, ss.BaseMinutes,
           ss.EffectiveUnplannedMinutes, ss.DowntimeEventCount, ss.NoReasonCount, ss.NoReasonMinutes,
           ss.Good, ss.Scrap, ss.NonRejectScrap, ss.FoundDownstreamScrap, ss.UnplacedScrap,
           ss.LastToolId, ss.IsActive, P.ActualStart AS ShiftActualStart, P.IsOpen
    FROM P
    INNER JOIN Oee.ShiftSummary ss ON ss.ShiftId = P.ShiftId
    WHERE P.IsStored = 1

    UNION ALL

    SELECT r.ShiftId, r.LocationId, r.RowKind, r.AreaFamily, r.ProductionAreaId, r.ParentUnitLocationId,
           r.PlannedMinutes, r.PlannedDowntimeMinutes, r.UnplannedDowntimeMinutes, r.BaseMinutes,
           r.EffectiveUnplannedMinutes, r.DowntimeEventCount, r.NoReasonCount, r.NoReasonMinutes,
           r.Good, r.Scrap, r.NonRejectScrap, r.FoundDownstreamScrap, r.UnplacedScrap,
           r.LastToolId, r.IsActive, P.ActualStart, P.IsOpen
    FROM P
    CROSS APPLY Oee.ufn_ShiftSummaryRows(P.ShiftId) r
    WHERE P.IsStored = 0
);
GO
