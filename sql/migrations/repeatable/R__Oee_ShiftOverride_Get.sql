-- =============================================
-- Procedure:   Oee.ShiftOverride_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Single shift-override row with its resolved FK names, for the editor popup.
--   Includes the row even when deprecated so the editor can render history.
--
--   Read proc: ONE result set, at most one row; empty = not found (no invented
--   404 status row). No OUTPUT params, no audit (FDS-11-011).
--
--   Times: StartTime / EndTime are LOCAL (Eastern) wall clock and are returned
--   as-is -- they are TIME(0), not instants, so no timezone conversion applies.
--   The audit-lifecycle instants (CreatedAt / UpdatedAt / DeprecatedAt) ARE
--   stored UTC and are converted to Eastern at this boundary with the mandatory
--   CAST(... AS DATETIME2(3)) -- a raw datetimeoffset breaks the Ignition JDBC
--   result read.
--
-- Parameters (input):
--   @Id BIGINT - Override to fetch.
--
-- Result set:
--   Id, LocationId, LocationCode, LocationName, ShiftScheduleId, ScheduleName,
--   ScheduleStartTime, ScheduleEndTime, BusinessDate, StartTime, EndTime,
--   Reason, IsDeprecated, CreatedAtEt, CreatedByInitials, UpdatedAtEt,
--   DeprecatedAtEt
--
-- Dependencies:
--   Tables: Oee.ShiftOverride, Oee.ShiftSchedule, Location.Location, Location.AppUser
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ov.Id,
        ov.LocationId,
        loc.Code                AS LocationCode,
        loc.Name                AS LocationName,
        ov.ShiftScheduleId,
        ss.Name                 AS ScheduleName,
        ss.StartTime            AS ScheduleStartTime,
        ss.EndTime              AS ScheduleEndTime,
        ov.BusinessDate,
        ov.StartTime,
        ov.EndTime,
        ov.Reason,
        CAST(CASE WHEN ov.DeprecatedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsDeprecated,
        CAST(ov.CreatedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAtEt,
        cu.Initials             AS CreatedByInitials,
        CAST(ov.UpdatedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS UpdatedAtEt,
        CAST(ov.DeprecatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DeprecatedAtEt
    FROM Oee.ShiftOverride ov
    INNER JOIN Location.Location loc ON loc.Id = ov.LocationId
    INNER JOIN Oee.ShiftSchedule ss  ON ss.Id  = ov.ShiftScheduleId
    LEFT  JOIN Location.AppUser  cu  ON cu.Id  = ov.CreatedByUserId
    WHERE ov.Id = @Id;
END
GO
