-- ============================================================
-- 2026-10-07_backdate_die_changeover.sql
--
-- ONE JOB: the die changeover on one press was recorded in the MES later than
-- it physically happened. Move the recorded changeover back to the true time:
-- end the outgoing die's mount there, start the incoming die's mount there.
--
-- WHY THE ROWS ARE WRONG. On DC3-M302 the MES shows 64A oil Pan-G mounted
-- until 2026-10-07 07:38 ET and 6MA Oil Pan D from 07:39 (assignment note:
-- "CHANGE OVER 10/6/26"). The die was physically changed on 10/6, so every
-- shift between the real changeover and 07:38 ran 6MA Oil Pan D while the MES
-- said 64A. The LOTs were relabelled by
-- 2026-10-07_relabel_lots_cast_on_wrong_die.sql; this fixes the mount history
-- they now disagree with. Until it is fixed,
-- Workorder.DieCastShiftReconciliation_Save refuses 10-06 Third Shift with
-- "6MA Oil Pan D ... was not mounted on DC3-M302".
--
-- THIS SCRIPT WRITES TO Tools.ToolAssignment DIRECTLY -- a known exception to
-- "go through the procs". Tools.ToolAssignment_Assign and _Release always
-- stamp SYSUTCDATETIME() and take no time parameter, so no deployed proc can
-- record a changeover in the past. On the owner's instruction (2026-10-07).
-- Each of the two rows gets an Audit.Audit_LogConfigChange 'Updated' row with
-- the old and new times, and the reason is appended to the row's Notes.
--
-- @Commit = 0 (default) runs the statements for real inside a transaction and
-- rolls back. Set @Commit = 1 in the working tree only; never commit it armed.
--
-- IT STOPS, CHANGING NOTHING, WHEN
--     * it cannot find exactly one closed mount of the outgoing die and the
--       one ACTIVE mount of the incoming die on that press, back to back
--     * the true changeover time is not inside the outgoing die's mount, or is
--       not earlier than the recorded changeover (this only ever backdates)
--     * the incoming die is on record somewhere else during the new span
--     * any LOT is still recorded on the OUTGOING die in the span being handed
--       to the incoming die. Relabel those first -- otherwise this would leave
--       them on a die the MES says was not in the press.
--
-- NOT IN SCOPE, deliberately.
--     * Die life / shot counts already credited to the outgoing die.
--     * Scrap, counter anchors and reconciliation headers recorded against the
--       outgoing die in the span. Counted in the report.
--     * Earlier changeovers on this press. Assignment 15 (6MA Oil Pan D,
--       recorded 2026-09-23 10:08) carries the note "mold changed 9/22/26" --
--       the same late-recording pattern. Not examined here.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @PressCode       NVARCHAR(50)  = N'DC3-M302';
DECLARE @OutDieName      NVARCHAR(200) = N'64A oil Pan-G';   -- DMO132, came OUT
DECLARE @InDieName       NVARCHAR(200) = N'6MA Oil Pan D';   -- DMO102, went IN
-- The plant knows only "10/6 first shift". 07:30 is the owner's placement
-- (2026-10-07): start of first shift, so every LOT entered on 302 from then on
-- is treated as 6MA Oil Pan D.
DECLARE @ChangeoverEt    DATETIME2(0)  = '2026-10-06 07:30';   -- REQUIRED. Eastern wall clock.
DECLARE @Reason          NVARCHAR(200) = N'Changeover recorded late; die was changed 10/6 first shift (time placed at 07:30).';
DECLARE @AppUserInitials NVARCHAR(10)  = N'JGP';
DECLARE @Commit          BIT           = 0;

-- ---- Resolve and guard, before any transaction ----
DECLARE @PressId BIGINT, @OutToolId BIGINT, @InToolId BIGINT, @AppUserId BIGINT, @N INT;

SELECT @PressId = Id FROM Location.Location WHERE Code = @PressCode;
IF @PressId IS NULL BEGIN RAISERROR(N'Press %s not found.', 16, 1, @PressCode); RETURN; END

SELECT @N = COUNT(*) FROM Tools.Tool WHERE Name = @OutDieName;
IF @N <> 1 BEGIN RAISERROR(N'Outgoing die "%s" matched %d tools; need exactly 1.', 16, 1, @OutDieName, @N); RETURN; END
SELECT @OutToolId = Id FROM Tools.Tool WHERE Name = @OutDieName;

SELECT @N = COUNT(*) FROM Tools.Tool WHERE Name = @InDieName;
IF @N <> 1 BEGIN RAISERROR(N'Incoming die "%s" matched %d tools; need exactly 1.', 16, 1, @InDieName, @N); RETURN; END
SELECT @InToolId = Id FROM Tools.Tool WHERE Name = @InDieName;

SELECT @AppUserId = Id FROM Location.AppUser WHERE Initials = @AppUserInitials AND DeprecatedAt IS NULL;
IF @AppUserId IS NULL BEGIN RAISERROR(N'AppUser %s not found.', 16, 1, @AppUserInitials); RETURN; END

IF @ChangeoverEt IS NULL BEGIN RAISERROR(N'Set @ChangeoverEt to when the die was physically changed (Eastern).', 16, 1); RETURN; END
DECLARE @ChangeoverUtc DATETIME2(3) = CAST(@ChangeoverEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

-- The incoming die's ACTIVE mount on this press, and the mount it replaced.
DECLARE @InRowId BIGINT, @InAssignedAt DATETIME2(3), @InNotes NVARCHAR(500);
SELECT @InRowId = Id, @InAssignedAt = AssignedAt, @InNotes = Notes
FROM Tools.ToolAssignment
WHERE ToolId = @InToolId AND CellLocationId = @PressId AND ReleasedAt IS NULL;
IF @InRowId IS NULL
BEGIN RAISERROR(N'%s is not the die currently mounted on %s. Nothing to backdate.', 16, 1, @InDieName, @PressCode); RETURN; END

DECLARE @OutRowId BIGINT, @OutAssignedAt DATETIME2(3), @OutReleasedAt DATETIME2(3), @OutNotes NVARCHAR(500), @OutToolFound BIGINT;
SELECT TOP 1 @OutRowId = Id, @OutToolFound = ToolId, @OutAssignedAt = AssignedAt,
             @OutReleasedAt = ReleasedAt, @OutNotes = Notes
FROM Tools.ToolAssignment
WHERE CellLocationId = @PressId AND ReleasedAt IS NOT NULL AND ReleasedAt <= @InAssignedAt
ORDER BY ReleasedAt DESC, Id DESC;
IF @OutRowId IS NULL OR @OutToolFound <> @OutToolId
BEGIN RAISERROR(N'The mount immediately before %s on %s is not %s. Check the die names.', 16, 1, @InDieName, @PressCode, @OutDieName); RETURN; END

DECLARE @Fmt NVARCHAR(30);
IF @ChangeoverUtc <= @OutAssignedAt
BEGIN
    SET @Fmt = CONVERT(NVARCHAR(16), CAST(@OutAssignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120);
    RAISERROR(N'Changeover time is at or before the outgoing die was mounted (%s ET).', 16, 1, @Fmt); RETURN;
END
IF @ChangeoverUtc >= @OutReleasedAt
BEGIN
    SET @Fmt = CONVERT(NVARCHAR(16), CAST(@OutReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120);
    RAISERROR(N'Changeover time is not earlier than the recorded one (%s ET). This script only backdates.', 16, 1, @Fmt); RETURN;
END

IF EXISTS (SELECT 1 FROM Tools.ToolAssignment
           WHERE ToolId = @InToolId AND Id <> @InRowId
             AND AssignedAt < @InAssignedAt AND ISNULL(ReleasedAt, '9999-12-31') > @ChangeoverUtc)
BEGIN RAISERROR(N'%s is on record as mounted somewhere else during the span being backdated.', 16, 1, @InDieName); RETURN; END

PRINT N'Press ' + @PressCode + N':  ' + @OutDieName + N'  ->  ' + @InDieName
    + N'    true changeover ' + CONVERT(NVARCHAR(16), @ChangeoverEt, 120) + N' ET'
    + N'    Commit: ' + CAST(@Commit AS NVARCHAR(1));

SELECT N'1 MOUNT ROWS (before)' AS Section, a.Id, tl.Name AS Die,
       CAST(a.AssignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS AssignedEt,
       CAST(a.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS ReleasedEt, a.Notes
FROM Tools.ToolAssignment a INNER JOIN Tools.Tool tl ON tl.Id = a.ToolId
WHERE a.Id IN (@OutRowId, @InRowId) ORDER BY a.AssignedAt;

-- LOTs still on the outgoing die in the span being handed over. A LOT counts
-- unless its credits put it on a different press.
IF OBJECT_ID(N'tempdb..#Left') IS NOT NULL DROP TABLE #Left;
SELECT l.Id AS LotId, l.LotName, sc.Code AS StatusCode, l.PieceCount,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS CreatedEt
INTO #Left
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.ToolId = @OutToolId
  AND l.CreatedAt >= @ChangeoverUtc AND l.CreatedAt < @InAssignedAt
  AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution c
                  WHERE c.LotId = l.Id AND c.CellLocationId IS NOT NULL AND c.CellLocationId <> @PressId);

SELECT N'2 LOTS STILL ON THE OUTGOING DIE IN THE SPAN (must be zero rows)' AS Section,
       LotName, StatusCode AS Status, PieceCount AS Pcs, CreatedEt
FROM #Left ORDER BY CreatedEt;

SELECT N'3 NOT IN SCOPE (stay on the outgoing die)' AS Section,
    (SELECT COUNT(*) FROM Workorder.RejectEvent r
      WHERE r.ToolId = @OutToolId AND r.CellLocationId = @PressId
        AND r.RecordedAt >= @ChangeoverUtc AND r.RecordedAt < @InAssignedAt)   AS ScrapRows,
    (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor x
      WHERE x.ToolId = @OutToolId AND x.CellLocationId = @PressId
        AND x.EventAt >= @ChangeoverUtc AND x.EventAt < @InAssignedAt)         AS CounterAnchors,
    (SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation h
      WHERE h.ToolId = @OutToolId AND h.CellLocationId = @PressId
        AND h.CreatedAt >= @ChangeoverUtc)                                     AS ReconciliationHeaders;

IF EXISTS (SELECT 1 FROM #Left)
BEGIN
    SET @N = (SELECT COUNT(*) FROM #Left);
    RAISERROR(N'%d LOT(s) are still recorded on the outgoing die in that span (Section 2). Relabel them first. Nothing was changed.', 16, 1, @N);
    RETURN;
END

DECLARE @Stamp NVARCHAR(200) = N' | Backdated ' + CONVERT(NVARCHAR(10), SYSDATETIME(), 23) + N' by ' + @AppUserInitials + N': ' + @Reason;
DECLARE @OldOut NVARCHAR(MAX), @NewOut NVARCHAR(MAX), @OldIn NVARCHAR(MAX), @NewIn NVARCHAR(MAX), @Desc NVARCHAR(1000);
DECLARE @PressJson NVARCHAR(MAX) = (SELECT Id, Code, Name FROM Location.Location WHERE Id = @PressId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
DECLARE @OutJson NVARCHAR(MAX) = (SELECT Id, Code, Name FROM Tools.Tool WHERE Id = @OutToolId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
DECLARE @InJson  NVARCHAR(MAX) = (SELECT Id, Code, Name FROM Tools.Tool WHERE Id = @InToolId  FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

BEGIN TRANSACTION;
BEGIN TRY

    -- ---- outgoing die: its mount ends at the true changeover ----
    SET @OldOut = (SELECT JSON_QUERY(@OutJson) AS ToolId, JSON_QUERY(@PressJson) AS CellLocationId,
                          CONVERT(NVARCHAR(23), @OutReleasedAt, 126) AS ReleasedAtUtc FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @NewOut = (SELECT JSON_QUERY(@OutJson) AS ToolId, JSON_QUERY(@PressJson) AS CellLocationId,
                          CONVERT(NVARCHAR(23), @ChangeoverUtc, 126) AS ReleasedAtUtc, @Reason AS Reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    UPDATE Tools.ToolAssignment
    SET ReleasedAt = @ChangeoverUtc, Notes = LEFT(CASE WHEN NULLIF(LTRIM(Notes), N'') IS NULL THEN STUFF(@Stamp, 1, 3, N'') ELSE Notes + @Stamp END, 500)
    WHERE Id = @OutRowId AND ReleasedAt = @OutReleasedAt;
    IF @@ROWCOUNT <> 1 RAISERROR(N'Outgoing mount row changed underneath. Rolled back.', 16, 1);

    SET @Desc = Audit.ufn_TruncateActivity(
        @OutDieName + N' ' + Audit.ufn_MidDot() + N' Mount on ' + @PressCode + N' ' + Audit.ufn_MidDot()
        + N' ~ReleasedAt backdated to ' + CONVERT(NVARCHAR(16), @ChangeoverEt, 120) + N' ET. ' + @Reason);
    EXEC Audit.Audit_LogConfigChange
        @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolAssignment', @EntityId = @OutRowId,
        @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
        @Description = @Desc, @OldValue = @OldOut, @NewValue = @NewOut;

    -- ---- incoming die: its mount starts at the true changeover ----
    SET @OldIn = (SELECT JSON_QUERY(@InJson) AS ToolId, JSON_QUERY(@PressJson) AS CellLocationId,
                         CONVERT(NVARCHAR(23), @InAssignedAt, 126) AS AssignedAtUtc FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    SET @NewIn = (SELECT JSON_QUERY(@InJson) AS ToolId, JSON_QUERY(@PressJson) AS CellLocationId,
                         CONVERT(NVARCHAR(23), @ChangeoverUtc, 126) AS AssignedAtUtc, @Reason AS Reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    UPDATE Tools.ToolAssignment
    SET AssignedAt = @ChangeoverUtc, Notes = LEFT(CASE WHEN NULLIF(LTRIM(Notes), N'') IS NULL THEN STUFF(@Stamp, 1, 3, N'') ELSE Notes + @Stamp END, 500)
    WHERE Id = @InRowId AND AssignedAt = @InAssignedAt AND ReleasedAt IS NULL;
    IF @@ROWCOUNT <> 1 RAISERROR(N'Incoming mount row changed underneath. Rolled back.', 16, 1);

    SET @Desc = Audit.ufn_TruncateActivity(
        @InDieName + N' ' + Audit.ufn_MidDot() + N' Mount on ' + @PressCode + N' ' + Audit.ufn_MidDot()
        + N' ~AssignedAt backdated to ' + CONVERT(NVARCHAR(16), @ChangeoverEt, 120) + N' ET. ' + @Reason);
    EXEC Audit.Audit_LogConfigChange
        @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolAssignment', @EntityId = @InRowId,
        @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
        @Description = @Desc, @OldValue = @OldIn, @NewValue = @NewIn;

    SELECT N'4 MOUNT ROWS (after)' AS Section, a.Id, tl.Name AS Die,
           CAST(a.AssignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS AssignedEt,
           CAST(a.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS ReleasedEt, a.Notes
    FROM Tools.ToolAssignment a INNER JOIN Tools.Tool tl ON tl.Id = a.ToolId
    WHERE a.Id IN (@OutRowId, @InRowId) ORDER BY a.AssignedAt;

    -- Which closed shifts the incoming die now covers on this press -- these
    -- are the ones the reconciliation form will accept for it.
    SELECT N'5 SHIFTS NOW COVERED BY THE INCOMING DIE' AS Section,
           CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS Shift, s.ActualStart AS StartEt, s.ActualEnd AS EndEt
    FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    WHERE CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) < @InAssignedAt
      AND CAST(ISNULL(s.ActualEnd, SYSDATETIME()) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) > @ChangeoverUtc
    ORDER BY s.ActualStart;

    IF @Commit = 1
    BEGIN
        COMMIT TRANSACTION;
        PRINT N'>>> COMMITTED.';
    END
    ELSE
    BEGIN
        ROLLBACK TRANSACTION;
        PRINT N'>>> DRY RUN -- rolled back. Set @Commit = 1 to apply.';
    END
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @E NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT N'>>> FAILED and rolled back: ' + @E;
    RAISERROR(@E, 16, 1);
END CATCH
GO
