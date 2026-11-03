-- =============================================
-- Procedure:   Oee.Dashboard_GetDowntimeByReason
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   Downtime by reason, Pareto order, for a period and scope (OEE dashboard
--   spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec
--   5.3, 5.4). Read from the SOURCE entries (Oee.ufn_ShiftDowntimeEntries, the
--   same definition the stored minutes use), not from the summary: detail
--   panels read source rows (6.7).
--     @LocationId  the location's own entries plus everything placed on it
--                  (a line includes its stations' entries)
--     @AreaFamily  entries placed in the family
--     neither      every entry placed in a family (the plant)
--   Entries with no reason are one row, IsNoReason = 1, counted unplanned.
--
-- Result set: ReasonCodeId NULL, ReasonCode, ReasonDescription,
--   ReasonTypeName, IsPlanned, IsNoReason, Minutes, EventCount.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetDowntimeByReason
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT,
    @AreaFamily    NVARCHAR(10) = NULL,
    @LocationId    BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.DowntimeReasonCodeId                         AS ReasonCodeId,
           ISNULL(rc.Code, N'(no reason)')                 AS ReasonCode,
           ISNULL(rc.Description, N'Downtime with no reason') AS ReasonDescription,
           rt.Name                                         AS ReasonTypeName,
           CAST(MAX(CAST(e.IsPlanned AS INT)) AS BIT)       AS IsPlanned,
           CAST(MAX(CAST(e.IsNoReason AS INT)) AS BIT)      AS IsNoReason,
           CAST(SUM(e.Minutes) AS DECIMAL(12,2))           AS Minutes,
           COUNT(*)                                        AS EventCount
    FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
    CROSS APPLY Oee.ufn_ShiftDowntimeEntries(p.ShiftId) e
    LEFT JOIN Oee.DowntimeReasonCode rc ON rc.Id = e.DowntimeReasonCodeId
    LEFT JOIN Oee.DowntimeReasonType rt ON rt.Id = rc.DowntimeReasonTypeId
    WHERE (@LocationId IS NOT NULL AND (e.LocationId = @LocationId OR e.PlacementLocationId = @LocationId))
       OR (@LocationId IS NULL AND @AreaFamily IS NOT NULL AND e.AreaFamily = @AreaFamily)
       OR (@LocationId IS NULL AND @AreaFamily IS NULL AND e.AreaFamily IS NOT NULL)
    GROUP BY e.DowntimeReasonCodeId, rc.Code, rc.Description, rt.Name
    ORDER BY SUM(e.Minutes) DESC, ISNULL(rc.Code, N'');
END
GO
