-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_GetByScope.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-16
-- Version:     1.2
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
--
--   v1.1 (2026-09-11): the current-shift view (@ShiftId NULL) ALSO lists
--              every event still OPEN (not ended, not voided) in scope,
--              whatever shift it started in -- a machine that went down last
--              shift must not vanish from the list at the shift change. An
--              explicit @ShiftId is unchanged: that shift's events only.
--
--   v1.2 (2026-11-16): performance only, result set unchanged (columns,
--              rows, order). The catch-all WHERE (@Shift IS NULL OR ShiftId =
--              @Shift OR open-and-not-voided) compiled to a scan of the whole
--              DowntimeEvent table on every call -- every shop-floor header
--              polls this every 30 s. The scope subtree is materialized once
--              into @Scope and the candidate event Ids are collected into @Ids
--              by up to two sargable INSERTs (this shift's events; then, for
--              the current-shift view only, events still open and not voided;
--              or every event in scope when no shift resolves), each seeking
--              an index on LocationId (IX_DowntimeEvent_Location_Shift,
--              migration 0127, or the filtered UX_..._OneOpenPerLocation).
--              The final SELECT is unchanged apart from driving from @Ids.
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

    DECLARE @Scope TABLE (Id BIGINT NOT NULL PRIMARY KEY);

    ;WITH Scope AS (
        SELECT @ScopeLocationId AS Id
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Scope s ON c.ParentLocationId = s.Id
        WHERE @IncludeDescendants = 1
    )
    INSERT INTO @Scope (Id)
    SELECT DISTINCT Id FROM Scope WHERE Id IS NOT NULL
    OPTION (MAXRECURSION 32);

    -- Candidate events. Same rows as the v1.1 catch-all WHERE
    --   (@Shift IS NULL OR ShiftId = @Shift OR (@ShiftId IS NULL AND open AND not voided)),
    -- split so each statement seeks an index on LocationId.
    DECLARE @Ids TABLE (Id BIGINT NOT NULL PRIMARY KEY);

    IF @Shift IS NULL
        -- no shift resolved (none open, none passed): every event in scope
        INSERT INTO @Ids (Id)
        SELECT de.Id
        FROM @Scope sc
        INNER JOIN Oee.DowntimeEvent de ON de.LocationId = sc.Id;
    ELSE
    BEGIN
        -- the shift's events (explicit @ShiftId, or the current open shift)
        INSERT INTO @Ids (Id)
        SELECT de.Id
        FROM @Scope sc
        INNER JOIN Oee.DowntimeEvent de ON de.LocationId = sc.Id
        WHERE de.ShiftId = @Shift;

        -- current-shift view only: every event still open, whatever its shift
        IF @ShiftId IS NULL
            INSERT INTO @Ids (Id)
            SELECT de.Id
            FROM @Scope sc
            INNER JOIN Oee.DowntimeEvent de ON de.LocationId = sc.Id
            WHERE de.EndedAt IS NULL
              AND de.VoidedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM @Ids i WHERE i.Id = de.Id);
    END

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
           COALESCE(de.DurationMinutes, CASE WHEN de.EndedAt IS NULL THEN NULL ELSE DATEDIFF(MINUTE, de.StartedAt, de.EndedAt) END) AS DurationMinutes,
           de.IsApproximate         AS IsApproximate,
           de.Remarks               AS Remarks,
           de.AppUserId             AS AppUserId,
           u.Initials               AS OperatorInitials,
           CAST(CASE WHEN de.EndedAt  IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
           CAST(CASE WHEN de.VoidedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsVoided,
           de.VoidReason            AS VoidReason
    FROM @Ids i
    INNER JOIN Oee.DowntimeEvent de       ON de.Id  = i.Id
    INNER JOIN Location.Location loc      ON loc.Id = de.LocationId
    INNER JOIN Oee.DowntimeSourceCode src ON src.Id = de.DowntimeSourceCodeId
    LEFT  JOIN Oee.DowntimeReasonCode rc  ON rc.Id  = de.DowntimeReasonCodeId
    LEFT  JOIN Location.AppUser u         ON u.Id   = de.AppUserId
    ORDER BY de.StartedAt DESC, de.Id DESC;
END;
GO
