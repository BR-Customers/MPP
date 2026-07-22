-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_GetByScope.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-21
-- Version:     1.0
-- Description: Terminal-scoped downtime read for the Downtime Manager popup
--              (Increment 1). Returns OPEN and CLOSED (and voided, flagged) events
--              whose LocationId is @ScopeLocationId (or a descendant when
--              @IncludeDescendants=1 -- the WIP subtree pattern), for a shift.
--              @ShiftId NULL => the current open shift (caller pages previous
--              shifts by passing a Shift.Id). Timestamps ET at the read boundary
--              (OI-36). Newest-first. READ proc: one result set, no status row,
--              no OUTPUT params (FDS-11-011); empty set = none in scope/shift.
--
--              Scope grain note (blast radius): new manager events log at the
--              resolved line; legacy/break/PLC events may be at descendant cells --
--              @IncludeDescendants=1 reads BOTH.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_GetByScope
    @ScopeLocationId    BIGINT,
    @IncludeDescendants BIT    = 1,
    @ShiftId            BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Shift BIGINT = @ShiftId;
    IF @Shift IS NULL
        SELECT TOP 1 @Shift = Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC;

    ;WITH Scope AS (
        SELECT @ScopeLocationId AS Id
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Scope s ON c.ParentLocationId = s.Id
        WHERE @IncludeDescendants = 1
    )
    SELECT de.Id                    AS DowntimeEventId,
           de.LocationId            AS LocationId,
           loc.Code                 AS LocationCode,
           @ScopeLocationId         AS ScopeLocationId,
           de.DowntimeReasonCodeId  AS DowntimeReasonCodeId,
           rc.Code                  AS ReasonCode,
           rc.Description           AS ReasonDescription,
           src.Code                 AS SourceCode,
           CAST(de.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS StartedAtEt,
           CAST(de.EndedAt   AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EndedAtEt,
           CASE WHEN de.EndedAt IS NULL THEN NULL ELSE DATEDIFF(MINUTE, de.StartedAt, de.EndedAt) END AS DurationMinutes,
           de.Remarks               AS Remarks,
           de.AppUserId             AS AppUserId,
           u.Initials               AS OperatorInitials,
           CAST(CASE WHEN de.EndedAt  IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
           CAST(CASE WHEN de.VoidedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsVoided,
           de.VoidReason            AS VoidReason
    FROM Oee.DowntimeEvent de
    INNER JOIN Location.Location loc      ON loc.Id = de.LocationId
    INNER JOIN Oee.DowntimeSourceCode src ON src.Id = de.DowntimeSourceCodeId
    LEFT  JOIN Oee.DowntimeReasonCode rc  ON rc.Id  = de.DowntimeReasonCodeId
    LEFT  JOIN Location.AppUser u         ON u.Id   = de.AppUserId
    WHERE de.LocationId IN (SELECT Id FROM Scope)
      AND (@Shift IS NULL OR de.ShiftId = @Shift)
    ORDER BY de.StartedAt DESC, de.Id DESC
    OPTION (MAXRECURSION 32);
END;
GO
