-- =============================================
-- Procedure:   Oee.Dashboard_GetDowntimeEntries
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   The unit drill-down's downtime entry list for one shift (OEE dashboard
--   spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec
--   5.4): the location's own entries and its stations', with the duration the
--   availability counts (Oee.ufn_ShiftDowntimeEntries). The Edit link opens
--   Popups/DowntimeEditor with DowntimeEventId. Not Oee.DowntimeEvent_GetByScope:
--   that proc reports DurationMinutes whenever present, while availability uses
--   it only for approximate entries (D17), and it has no station flag or
--   reason type.
--
-- Result set: DowntimeEventId, LocationId, LocationName, IsStation, Minutes,
--   IsApproximate, ReasonCode NULL, ReasonTypeName NULL, IsPlanned,
--   ByInitials, StartedAtEt. Oldest first.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetDowntimeEntries
    @AnchorShiftId BIGINT,
    @LocationId    BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.DowntimeEventId,
           e.LocationId,
           l.Name                                                         AS LocationName,
           CAST(CASE WHEN e.LocationId <> @LocationId THEN 1 ELSE 0 END AS BIT) AS IsStation,
           CAST(e.Minutes AS DECIMAL(12,2))                               AS Minutes,
           e.IsApproximate,
           rc.Code                                                        AS ReasonCode,
           rt.Name                                                        AS ReasonTypeName,
           e.IsPlanned,
           u.Initials                                                     AS ByInitials,
           CAST(e.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS StartedAtEt
    FROM Oee.ufn_ShiftDowntimeEntries(@AnchorShiftId) e
    INNER JOIN Location.Location l ON l.Id = e.LocationId
    LEFT JOIN Oee.DowntimeReasonCode rc ON rc.Id = e.DowntimeReasonCodeId
    LEFT JOIN Oee.DowntimeReasonType rt ON rt.Id = rc.DowntimeReasonTypeId
    LEFT JOIN Location.AppUser u        ON u.Id  = e.AppUserId
    WHERE e.LocationId = @LocationId OR e.PlacementLocationId = @LocationId
    ORDER BY e.StartedAt, e.DowntimeEventId;
END
GO
