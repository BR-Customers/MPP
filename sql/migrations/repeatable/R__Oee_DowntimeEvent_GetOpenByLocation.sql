-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_GetOpenByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: READ proc for the Downtime Entry view + the Shift-end Summary's
--              "open downtime" list (Arc 2 Phase 8, FDS-09-015). Returns OPEN
--              downtime events at a Location, oldest-first. READ proc: no
--              @Status/@Message, one result set; empty set = none open.
--              StartedAt is converted to Eastern at the read boundary (OI-36).
--              MVP scope = exact Location; Cell-subtree scoping is a future
--              refinement (FDS-09-015 "+ descendants").
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_GetOpenByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT de.Id                  AS DowntimeEventId,
           de.LocationId          AS LocationId,
           loc.Code               AS LocationCode,
           de.DowntimeReasonCodeId AS DowntimeReasonCodeId,
           rc.Code                AS ReasonCode,
           de.DowntimeSourceCodeId AS DowntimeSourceCodeId,
           src.Code               AS SourceCode,
           de.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS StartedAtEt,
           de.AppUserId           AS AppUserId,
           de.ShotCount           AS ShotCount
    FROM Oee.DowntimeEvent de
    INNER JOIN Location.Location loc      ON loc.Id = de.LocationId
    INNER JOIN Oee.DowntimeSourceCode src ON src.Id = de.DowntimeSourceCodeId
    LEFT  JOIN Oee.DowntimeReasonCode rc  ON rc.Id  = de.DowntimeReasonCodeId
    WHERE de.LocationId = @LocationId
      AND de.EndedAt IS NULL
    ORDER BY de.StartedAt ASC, de.Id ASC;
END;
GO
