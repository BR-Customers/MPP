-- =============================================
-- Procedure:   Oee.ShiftOverride_Restamp
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   THE RESTAMP. Re-attributes already-recorded rows whose correct shift changed
--   because an override was created, edited or deprecated. Spec sec 4.3
--   (docs/superpowers/specs/2026-08-19-shift-override-attribution-design.md).
--
--   This is the load-bearing half of the feature. Design D3: nobody knows a
--   shift ran long until after it did, so a RETROACTIVE override is the NORMAL
--   path. Write-time resolution alone would leave the 15:00 basket stamped
--   Second forever; without this proc an override created after the fact changes
--   nothing at all.
--
--   INTERNAL WORKER -- EMITS NO RESULT SET, OWNS NO TRANSACTION.
--   Deliberate, and both halves are load-bearing:
--     * No result set, so the INSERT-EXEC-captured status-row procs
--       (Oee.ShiftOverride_Create / _Update / _Deprecate) can EXEC it from
--       inside their own transaction without polluting their single result set
--       -- exactly how Audit.Audit_LogOperation is used. Returning a status row
--       here would make those three procs illegal (FDS-11-011, one result set
--       per proc; nested INSERT-EXEC is not permitted).
--     * No transaction and NO ROLLBACK, so it can never throw Msg 3915 inside a
--       caller's open transaction. Every caller wraps it; on error it simply
--       lets the exception propagate to the caller's CATCH, which is the only
--       legal ROLLBACK site.
--   Oee.ShiftOverride_Apply is the public, status-row, re-runnable entry point.
--
--   IDEMPOTENT. It computes, per row, the shift the resolver says the row
--   belongs to, and writes only where that differs from what is stored.
--   Re-running immediately changes no data (the audit row it writes each time is
--   the record that an apply happened, and reports 0 moved).
--
--   REVERSIBLE. Deprecating the override and re-applying reverts the equipment
--   to the plant-global window and moves the same rows back -- the resolver is
--   the only source of the answer in both directions.
--
--   ---- SCOPE (read this -- it is wider than spec sec 4.3 assumes) ----
--   Spec sec 4.3 bounds the restamp to "the two shifts either side of each moved
--   boundary". This implementation instead bounds it to
--     [BusinessDate - 1 day 00:00 local, BusinessDate + 2 days 00:00 local)
--   for the ONE equipment named by the override. Reasons:
--     * An override can move EITHER boundary, an edit can move a boundary in
--       either direction, and a midnight-crossing shift extended past midnight
--       reaches into the next calendar day. Enumerating "the two shifts either
--       side" correctly for all of those is more code and more ways to miss a
--       row than simply recomputing a bounded neighbourhood.
--     * Recomputing is SAFE at any width: the resolver is total, so a row whose
--       correct shift equals its stored shift is not written. A wider scope can
--       only find MORE rows that were already wrong; it can never produce a
--       wrong answer.
--   The cost is bounded and small: three days of ONE press's downtime events and
--   die-cast contribution rows.
--
--   ---- WHAT IS IN SCOPE ----
--     * Oee.DowntimeEvent           by LocationId  (already the OEE scope
--                                   location; Oee.ShiftOverride.LocationId is
--                                   validated to be self-scoping equipment).
--                                   Voided events are skipped.
--     * Workorder.DieCastContribution by CellLocationId (added by migration
--                                   0061 for exactly this; OI-2 / spec sec 5).
--                                   Rows with CellLocationId NULL -- a die with
--                                   no active assignment at EventAt -- are
--                                   EXCLUDED, not guessed.
--   NOT in scope: Workorder.RejectEvent has no ShiftId at all (see
--   R__Workorder_DieCastSupervisor_GetShiftTotals.sql's "SCRAP IS DELIBERATELY
--   ABSENT" note), and Oee.EndOfShiftEntry is submitted against an
--   operator-chosen shift, not a resolved one.
--
--   A row whose instant resolves to NO shift (resolver returns zero rows) or to
--   a shift with no runtime Oee.Shift instance keeps whatever it already has.
--   The restamp only ever MOVES attribution between real shifts; it never wipes
--   one to NULL.
--
--   ---- TIME BASIS (OI-38) ----
--   Oee.ShiftOverride.BusinessDate is a LOCAL Eastern calendar date. The event
--   columns it is compared against -- Oee.DowntimeEvent.StartedAt and
--   Workorder.DieCastContribution.EventAt -- are UTC. The scope bounds are
--   therefore built in local, then converted ONCE with AT TIME ZONE (DST-aware)
--   and the mandatory CAST(... AS DATETIME2(3)); a raw datetimeoffset breaks the
--   Ignition JDBC result read. Per-row attribution never converts anything --
--   Oee.ufn_ShiftIdForInstant takes the UTC instant directly and does its own
--   single conversion internally.
--
-- Parameters (input):
--   @ShiftOverrideId BIGINT - the override that changed. Read even when
--                             DeprecatedAt is set (that IS the deprecate path).
--   @AppUserId       BIGINT - audit attribution.
--
-- Result set: NONE. See header.
--
-- Dependencies:
--   Tables: Oee.ShiftOverride, Oee.DowntimeEvent, Workorder.DieCastContribution,
--           Oee.Shift, Oee.ShiftSchedule, Location.Location
--   Funcs:  Oee.ufn_ShiftIdForInstant, Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--   Procs:  Audit.Audit_LogConfigChange
--
-- Error Handling:
--   None of its own -- no TRY/CATCH, no ROLLBACK. Errors propagate to the
--   caller's CATCH by design (see header).
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (shift-override attribution, sec 4.3).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_Restamp
    @ShiftOverrideId BIGINT,
    @AppUserId       BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LocationId      BIGINT;
    DECLARE @ShiftScheduleId BIGINT;
    DECLARE @BusinessDate    DATE;

    SELECT @LocationId      = ov.LocationId,
           @ShiftScheduleId = ov.ShiftScheduleId,
           @BusinessDate    = ov.BusinessDate
    FROM Oee.ShiftOverride ov
    WHERE ov.Id = @ShiftOverrideId;

    IF @LocationId IS NULL
        RETURN;   -- no such override: nothing to restamp, and not this proc's job to complain

    DECLARE @LocCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @LocationId);

    -- Local scope bounds -> UTC, once. AT TIME ZONE is DST-aware; the CAST back
    -- to DATETIME2(3) is mandatory (no datetimeoffset may escape).
    DECLARE @ScopeStartLocal DATETIME2(3) = CAST(DATEADD(DAY, -1, @BusinessDate) AS DATETIME2(3));
    DECLARE @ScopeEndLocal   DATETIME2(3) = CAST(DATEADD(DAY,  2, @BusinessDate) AS DATETIME2(3));
    DECLARE @ScopeStartUtc   DATETIME2(3) =
        CAST(@ScopeStartLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @ScopeEndUtc     DATETIME2(3) =
        CAST(@ScopeEndLocal   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    -- SrcKind: 1 = Oee.DowntimeEvent, 2 = Workorder.DieCastContribution
    DECLARE @Moves TABLE (
        SrcKind    TINYINT NOT NULL,
        RowId      BIGINT  NOT NULL,
        OldShiftId BIGINT  NULL,
        NewShiftId BIGINT  NOT NULL
    );

    INSERT INTO @Moves (SrcKind, RowId, OldShiftId, NewShiftId)
    SELECT 1, de.Id, de.ShiftId, r.ShiftId
    FROM Oee.DowntimeEvent de
    CROSS APPLY Oee.ufn_ShiftIdForInstant(de.LocationId, de.StartedAt) r
    WHERE de.LocationId = @LocationId
      AND de.VoidedAt IS NULL
      AND de.StartedAt >= @ScopeStartUtc
      AND de.StartedAt <  @ScopeEndUtc
      AND r.ShiftId IS NOT NULL
      AND (de.ShiftId IS NULL OR de.ShiftId <> r.ShiftId);

    INSERT INTO @Moves (SrcKind, RowId, OldShiftId, NewShiftId)
    SELECT 2, dc.Id, dc.ShiftId, r.ShiftId
    FROM Workorder.DieCastContribution dc
    CROSS APPLY Oee.ufn_ShiftIdForInstant(dc.CellLocationId, dc.EventAt) r
    WHERE dc.CellLocationId = @LocationId       -- NULL CellLocationId excluded (spec sec 5)
      AND dc.EventAt >= @ScopeStartUtc
      AND dc.EventAt <  @ScopeEndUtc
      AND r.ShiftId IS NOT NULL
      AND (dc.ShiftId IS NULL OR dc.ShiftId <> r.ShiftId);

    UPDATE de
    SET    de.ShiftId = m.NewShiftId
    FROM   Oee.DowntimeEvent de
    INNER JOIN @Moves m ON m.SrcKind = 1 AND m.RowId = de.Id;

    UPDATE dc
    SET    dc.ShiftId = m.NewShiftId
    FROM   Workorder.DieCastContribution dc
    INNER JOIN @Moves m ON m.SrcKind = 2 AND m.RowId = dc.Id;

    -- ---- ONE audit row per apply, summarising what moved ----
    DECLARE @Total     INT = (SELECT COUNT(*) FROM @Moves);
    DECLARE @Downtime  INT = (SELECT COUNT(*) FROM @Moves WHERE SrcKind = 1);
    DECLARE @Contrib   INT = (SELECT COUNT(*) FROM @Moves WHERE SrcKind = 2);
    DECLARE @PairCount INT = (SELECT COUNT(*) FROM (SELECT DISTINCT OldShiftId, NewShiftId FROM @Moves) p);

    DECLARE @FromName NVARCHAR(100) = NULL;
    DECLARE @ToName   NVARCHAR(100) = NULL;

    IF @PairCount = 1
        SELECT TOP 1
               @FromName = ISNULL(ssFrom.Name, N'(unattributed)'),
               @ToName   = ssTo.Name
        FROM   @Moves m
        LEFT  JOIN Oee.Shift shFrom       ON shFrom.Id = m.OldShiftId
        LEFT  JOIN Oee.ShiftSchedule ssFrom ON ssFrom.Id = shFrom.ShiftScheduleId
        INNER JOIN Oee.Shift shTo         ON shTo.Id   = m.NewShiftId
        INNER JOIN Oee.ShiftSchedule ssTo   ON ssTo.Id   = shTo.ShiftScheduleId;

    -- Convention: <SUBJECT> <MidDot> <CATEGORY> <MidDot> <ACTION>
    DECLARE @ActivityRaw NVARCHAR(MAX) =
        ISNULL(@LocCode, N'(unknown)') + N' ' + Audit.ufn_MidDot()
        + N' Shift Override ' + Audit.ufn_MidDot()
        + N' Reattributed ' + CAST(@Total AS NVARCHAR(10)) + N' events'
        + CASE
            WHEN @Total = 0     THEN N''
            WHEN @PairCount = 1 THEN N' from ' + @FromName + N' to ' + @ToName
            ELSE N' across ' + CAST(@PairCount AS NVARCHAR(10)) + N' shift pairs'
          END;
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

    DECLARE @NewValue NVARCHAR(MAX) = (
        SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                           FROM Location.Location loc WHERE loc.Id = @LocationId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                AS LocationId,
               JSON_QUERY((SELECT ss.Id, ss.Name AS Code, ss.Name
                           FROM Oee.ShiftSchedule ss WHERE ss.Id = @ShiftScheduleId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                AS ShiftScheduleId,
               JSON_QUERY((SELECT ov.Id,
                                  CONVERT(NVARCHAR(8),  ov.StartTime, 108) AS StartTime,
                                  CONVERT(NVARCHAR(8),  ov.EndTime,   108) AS EndTime,
                                  CASE WHEN ov.DeprecatedAt IS NULL THEN N'Active' ELSE N'Deprecated' END AS State
                           FROM Oee.ShiftOverride ov WHERE ov.Id = @ShiftOverrideId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                AS ShiftOverrideId,
               CONVERT(NVARCHAR(10), @BusinessDate, 23)                          AS BusinessDate,
               CONVERT(NVARCHAR(23), @ScopeStartLocal, 121)                      AS ScopeStartLocal,
               CONVERT(NVARCHAR(23), @ScopeEndLocal,   121)                      AS ScopeEndLocal,
               @Total                                                            AS MovedTotal,
               @Downtime                                                         AS MovedDowntimeEvents,
               @Contrib                                                          AS MovedDieCastContributions,
               @PairCount                                                        AS DistinctShiftPairs
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    EXEC Audit.Audit_LogConfigChange
        @AppUserId         = @AppUserId,
        @LogEntityTypeCode = N'ShiftOverride',
        @EntityId          = @ShiftOverrideId,
        @LogEventTypeCode  = N'ShiftAttributionRestamped',
        @LogSeverityCode   = N'Info',
        @Description       = @Activity,
        @OldValue          = NULL,
        @NewValue          = @NewValue;
END
GO
