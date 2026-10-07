-- ============================================================
-- 2026-10-07_relabel_lots_cast_on_wrong_die.sql
--
-- ONE JOB: every LOT recorded against die @FromDieName in the window below was
-- really cast on die @ToDieName. Re-point those LOTs (part, die, cavity) and
-- the die-cast rows that hang off them, and leave a correction record on each.
--
-- OUTCOME. Applied on prod 2026-10-07 12:09 ET (JGP), after a clean dry run at
-- 12:06: 3 LOTs relabelled (10629856, 10629857, 10631498; 157 pieces),
-- 64A oil Pan-G / 1120A-64AA -> 6MA Oil Pan D / 11200-6MAA-J010, 3 contribution
-- rows, 0 reject rows, 3 LOT notes. Piece counts were not touched. Still to do
-- through the shift reconciliation form for 10-06 Third Shift on Machine 302:
-- the five tags never entered (10629858-61, 10631497) and 10631498 37 -> 64.
-- A re-run now stops at "No LOTs on the wrong die in that window".
--
-- WHY THE ROWS ARE WRONG. The wrong die was selected in the MES while the
-- other die was physically in the press, so each basket was minted with the
-- wrong ToolId -- and, because the part comes from the die's cavity, the wrong
-- ItemId and ToolCavityId too.
--
-- HOW THE NEW PART IS CHOSEN. It is not typed in. For each LOT the script
-- finds the cavity on @ToDieName with the SAME cavity letter the LOT carries
-- today and takes that cavity's part. No such cavity, or more than one (a
-- family die repeats letters once per part), and the LOT is BLOCKED -- the
-- script will not guess which part a basket holds.
--
-- THIS SCRIPT WRITES TO TABLES DIRECTLY, AND THAT IS A KNOWN EXCEPTION.
-- prod-release-context-pack/09 says "go through the procs, never a raw
-- UPDATE". No deployed proc can change a LOT's part or die: Lot_Update and
-- Lot_UpdateAttribute cover PieceCount / Weight / VendorLot only. So the
-- identity UPDATEs here are raw, on the owner's instruction (2026-10-07), and
-- the audit trail a proc would have written is written by hand instead, using
-- the same writers the procs use:
--     Lots.LotAttributeChange   one row per changed field (ItemId, ToolId,
--                               ToolCavityId), old -> new, readable values
--     Audit.Audit_LogOperation  one 'LotUpdated' row per LOT, resolved JSON
--     Lots.LotNote_Add          one note per LOT, visible on the LOT's notes
--                               (skipped with a PRINT if 0107 is not deployed)
-- If this is ever needed a second time it should become a proc.
--
-- @Commit = 0 (default) runs every statement for real inside a transaction and
-- rolls back, so the rehearsal exercises exactly what the armed run will do.
-- Set @Commit = 1 in the working tree only; never commit this file armed.
--
-- WHAT IT TOUCHES
--     Lots.Lot                       ItemId, ToolId, ToolCavityId
--     Workorder.DieCastContribution  ToolCavityId          (rows for these LOTs)
--     Workorder.RejectEvent          ItemId, ToolId, ToolCavityId
--                                    (rows for these LOTs that carry the old die)
--
-- A LOT IS BLOCKED, AND THE WHOLE RUN STOPS, WHEN
--     * there is no single matching cavity on the target die (see above)
--     * it has been consumed or has produced something (ConsumptionEvent)
--     * it has genealogy in either direction (split / merge / consumption)
--     * it has ProductionEvent rows and @AllowProductionEvents = 0 -- those
--       point at operation templates resolved from the OLD part's route
-- Narrow the window or use @OnlyLotNames to leave a blocked LOT out.
--
-- NOT IN SCOPE, deliberately. Each is COUNTED in the report so it is visible:
--     * Tools.ToolAssignment -- the mount history still says the old die was
--       in the press. The reconciliation landing list reads it, so the old die
--       will still appear there for those shifts, now with no production.
--     * Die life / shot counts already credited to the old die.
--     * Workorder.DieCastCounterAnchor and DieCastShiftReconciliation rows
--       keyed on the old die. Shift x press x die is their identity; moving
--       them is a reconciliation decision, not a relabel.
--     * Basketless scrap (RejectEvent.LotId IS NULL) on the old die. With no
--       LOT there is nothing here that proves which die it came from.
--     * Lot.MaxPieceCount (basket size of the old part) and the legacy
--       Lot.DieNumber column.
--     * Printed LTT tickets. The paper still shows the old part number.
--     * Which SHIFT the contribution rows are stamped with. Separate issue.
--
-- SIDE EFFECT TO KNOW ABOUT. Shot watermarks are scoped by die and cavity per
-- shift. Contribution rows moved onto the target die's cavity start counting
-- toward that cavity's watermark for the shifts they are stamped with. If the
-- target die is running an OPEN shift on the same press right now, run this
-- between baskets, not mid-entry.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;   -- Lots.Lot carries a filtered index; DML needs this

-- ---- Parameters. Names, not ids. ----
-- 2026-10-07: Machine 302, third shift 10/06. The press sheet lists eight
-- tags; only these three exist in the MES (the other five were never entered
-- and go in through the shift reconciliation form AFTER this runs).
DECLARE @FromDieName     NVARCHAR(200) = N'64A oil Pan-G';   -- DMO132
DECLARE @ToDieName       NVARCHAR(200) = N'6MA Oil Pan D';   -- DMO102
DECLARE @CreatedFromEt   DATETIME2(0)  = '2026-10-06 22:00'; -- REQUIRED. LOT created at/after, Eastern wall clock
DECLARE @CreatedToEt     DATETIME2(0)  = '2026-10-07 08:00'; -- REQUIRED. LOT created before,   Eastern wall clock
DECLARE @PressCode       NVARCHAR(50)  = NULL;   -- optional: only LOTs with Lot.ProducedAtLocationId = this press.
                                                 -- That column is NULL on every normally-minted LOT (0082 fills it
                                                 -- for cutover and reconciliation mints only), so leave this NULL
                                                 -- for live production.
DECLARE @OnlyLotNames    NVARCHAR(MAX) = N'10629856,10629857,10631498';   -- NULL = every LOT in the window
DECLARE @Reason          NVARCHAR(300) = N'Wrong die selected at Machine 302 on third shift 10/06; castings were run on 6MA Oil Pan D.';
DECLARE @AppUserInitials NVARCHAR(10)  = N'JGP';
DECLARE @AllowProductionEvents BIT     = 0;
DECLARE @Commit          BIT           = 0;

-- ---- Resolve and guard, before any transaction ----
DECLARE @FromToolId BIGINT, @ToToolId BIGINT, @AppUserId BIGINT, @PressId BIGINT;
DECLARE @N INT;

SELECT @N = COUNT(*) FROM Tools.Tool WHERE Name = @FromDieName;
IF @N <> 1 BEGIN RAISERROR(N'Wrong die "%s" matched %d tools; need exactly 1.', 16, 1, @FromDieName, @N); RETURN; END
SELECT @FromToolId = Id FROM Tools.Tool WHERE Name = @FromDieName;

SELECT @N = COUNT(*) FROM Tools.Tool WHERE Name = @ToDieName;
IF @N <> 1 BEGIN RAISERROR(N'True die "%s" matched %d tools; need exactly 1.', 16, 1, @ToDieName, @N); RETURN; END
SELECT @ToToolId = Id FROM Tools.Tool WHERE Name = @ToDieName;

IF @FromToolId = @ToToolId BEGIN RAISERROR(N'Wrong die and true die are the same tool.', 16, 1); RETURN; END
IF @CreatedFromEt IS NULL OR @CreatedToEt IS NULL OR @CreatedToEt <= @CreatedFromEt
BEGIN RAISERROR(N'Set @CreatedFromEt and @CreatedToEt (Eastern) to bound the correction.', 16, 1); RETURN; END

SELECT @AppUserId = Id FROM Location.AppUser WHERE Initials = @AppUserInitials AND DeprecatedAt IS NULL;
IF @AppUserId IS NULL BEGIN RAISERROR(N'AppUser %s not found.', 16, 1, @AppUserInitials); RETURN; END

IF @PressCode IS NOT NULL
BEGIN
    SELECT @PressId = Id FROM Location.Location WHERE Code = @PressCode;
    IF @PressId IS NULL BEGIN RAISERROR(N'Press %s not found.', 16, 1, @PressCode); RETURN; END
END

DECLARE @FromUtc DATETIME2(3) = CAST(@CreatedFromEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @ToUtc   DATETIME2(3) = CAST(@CreatedToEt   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

IF OBJECT_ID(N'tempdb..#S') IS NOT NULL DROP TABLE #S;
CREATE TABLE #S (
    LotId BIGINT NOT NULL PRIMARY KEY, LotName NVARCHAR(50) NOT NULL, StatusCode NVARCHAR(50) NOT NULL,
    PieceCount INT NOT NULL, CreatedEt DATETIME2(0) NOT NULL, Press NVARCHAR(200) NULL,
    OldItemId BIGINT NOT NULL, OldPart NVARCHAR(100) NULL,
    OldCavityId BIGINT NULL, CavityCode NVARCHAR(10) NULL,
    NewCavityId BIGINT NULL, NewItemId BIGINT NULL, NewPart NVARCHAR(100) NULL,
    CavityMatches INT NOT NULL DEFAULT (0),
    Contributions INT NOT NULL DEFAULT (0), Rejects INT NOT NULL DEFAULT (0),
    ProductionEvents INT NOT NULL DEFAULT (0), Labels INT NOT NULL DEFAULT (0),
    Blocker NVARCHAR(400) NULL);

INSERT INTO #S (LotId, LotName, StatusCode, PieceCount, CreatedEt, Press, OldItemId, OldPart, OldCavityId, CavityCode)
SELECT l.Id, l.LotName, sc.Code, l.PieceCount,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)),
       pl.Name, l.ItemId, i.PartNumber, l.ToolCavityId, tc.CavityCode
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
LEFT  JOIN Tools.ToolCavity tc   ON tc.Id = l.ToolCavityId
LEFT  JOIN Location.Location pl  ON pl.Id = l.ProducedAtLocationId
WHERE l.ToolId = @FromToolId
  AND l.CreatedAt >= @FromUtc AND l.CreatedAt < @ToUtc
  AND (@PressId IS NULL OR l.ProducedAtLocationId = @PressId)
  AND (@OnlyLotNames IS NULL
       OR l.LotName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@OnlyLotNames, N',')));

IF NOT EXISTS (SELECT 1 FROM #S) BEGIN RAISERROR(N'No LOTs on the wrong die in that window. Nothing to do.', 16, 1); RETURN; END

-- A named tag that did not land in scope is a misread digit, a LOT already
-- corrected, or one outside the window. Never drop it silently.
IF @OnlyLotNames IS NOT NULL
BEGIN
    DECLARE @Missing NVARCHAR(MAX) = (
        SELECT STRING_AGG(LTRIM(RTRIM(value)), N', ') FROM STRING_SPLIT(@OnlyLotNames, N',')
        WHERE LTRIM(RTRIM(value)) <> N'' AND LTRIM(RTRIM(value)) NOT IN (SELECT LotName FROM #S));
    IF @Missing IS NOT NULL
    BEGIN RAISERROR(N'Listed but not found on the wrong die in the window: %s. Nothing was changed.', 16, 1, @Missing); RETURN; END
END

-- Target cavity: same letter on the true die, live cavities only.
UPDATE s SET s.CavityMatches = m.Cnt
FROM #S s
CROSS APPLY (SELECT COUNT(*) AS Cnt FROM Tools.ToolCavity t
             WHERE t.ToolId = @ToToolId AND t.CavityCode = s.CavityCode AND t.DeprecatedAt IS NULL) m;

UPDATE s SET s.NewCavityId = t.Id, s.NewItemId = t.ItemId, s.NewPart = i.PartNumber
FROM #S s
INNER JOIN Tools.ToolCavity t ON t.ToolId = @ToToolId AND t.CavityCode = s.CavityCode AND t.DeprecatedAt IS NULL
LEFT  JOIN Parts.Item i       ON i.Id = t.ItemId
WHERE s.CavityMatches = 1;

UPDATE s SET
    s.Contributions    = (SELECT COUNT(*) FROM Workorder.DieCastContribution c WHERE c.LotId = s.LotId),
    s.Rejects          = (SELECT COUNT(*) FROM Workorder.RejectEvent r WHERE r.LotId = s.LotId),
    s.ProductionEvents = (SELECT COUNT(*) FROM Workorder.ProductionEvent p WHERE p.LotId = s.LotId),
    s.Labels           = (SELECT COUNT(*) FROM Lots.LotLabel b WHERE b.LotId = s.LotId)
FROM #S s;

UPDATE s SET s.Blocker =
    CASE WHEN s.CavityCode IS NULL   THEN N'LOT has no cavity; cannot map it onto the true die.'
         WHEN s.CavityMatches = 0    THEN N'True die has no live cavity "' + s.CavityCode + N'".'
         WHEN s.CavityMatches > 1    THEN N'True die has cavity "' + s.CavityCode + N'" for more than one part (family die); part is ambiguous.'
         WHEN s.NewItemId IS NULL    THEN N'Matching cavity on the true die has no part mapped.'
         WHEN EXISTS (SELECT 1 FROM Workorder.ConsumptionEvent ce
                      WHERE ce.SourceLotId = s.LotId OR ce.ProducedLotId = s.LotId)
                                     THEN N'LOT has consumption events.'
         WHEN EXISTS (SELECT 1 FROM Lots.LotGenealogy g
                      WHERE g.ParentLotId = s.LotId OR g.ChildLotId = s.LotId)
                                     THEN N'LOT has genealogy (split / merge / consumption).'
         WHEN s.ProductionEvents > 0 AND @AllowProductionEvents = 0
                                     THEN N'LOT has ProductionEvent rows resolved from the old part''s route (@AllowProductionEvents = 0).'
    END
FROM #S s;

PRINT N'Wrong die: ' + @FromDieName + N'   ->   true die: ' + @ToDieName
    + N'    Commit: ' + CAST(@Commit AS NVARCHAR(1));

SELECT N'1 SCOPE (before)' AS Section, LotName, StatusCode AS Status, PieceCount AS Pcs, CreatedEt, Press,
       OldPart, CavityCode AS Cavity, NewPart, Contributions, Rejects, ProductionEvents, Labels AS PrintedLabels, Blocker
FROM #S ORDER BY CreatedEt;

SELECT N'2 SCOPE TOTALS' AS Section, COUNT(*) AS Lots, SUM(PieceCount) AS Pieces,
       SUM(Contributions) AS ContributionRows, SUM(Rejects) AS RejectRows,
       SUM(CASE WHEN Blocker IS NOT NULL THEN 1 ELSE 0 END) AS BlockedLots
FROM #S;

SELECT N'3 NOT IN SCOPE (still on the wrong die afterwards)' AS Section,
    (SELECT COUNT(*) FROM Tools.ToolAssignment a
      WHERE a.ToolId = @FromToolId AND a.AssignedAt < @ToUtc
        AND ISNULL(a.ReleasedAt, '9999-12-31') > @FromUtc)                           AS MountHistoryRows,
    (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor x
      WHERE x.ToolId = @FromToolId AND x.EventAt >= @FromUtc AND x.EventAt < @ToUtc) AS CounterAnchors,
    (SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation h
      WHERE h.ToolId = @FromToolId AND h.CreatedAt >= @FromUtc)                      AS ReconciliationHeaders,
    (SELECT COUNT(*) FROM Workorder.RejectEvent r
      WHERE r.ToolId = @FromToolId AND r.LotId IS NULL
        AND r.RecordedAt >= @FromUtc AND r.RecordedAt < @ToUtc)                      AS BasketlessScrapRows,
    (SELECT COUNT(*) FROM Lots.Lot l
      WHERE l.ToolId = @FromToolId AND l.Id NOT IN (SELECT LotId FROM #S))           AS OtherLotsOnWrongDieOutsideWindow;

IF EXISTS (SELECT 1 FROM #S WHERE Blocker IS NOT NULL)
BEGIN RAISERROR(N'One or more LOTs are blocked (see Section 1, Blocker). Nothing was changed.', 16, 1); RETURN; END

DECLARE @HasNotes BIT = CASE WHEN OBJECT_ID(N'Lots.LotNote_Add', N'P') IS NULL THEN 0 ELSE 1 END;
IF @HasNotes = 0 PRINT N'Lots.LotNote_Add is not deployed here -- LOT notes are skipped; attribute-change and audit rows are still written.';

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Today NVARCHAR(10) = CONVERT(NVARCHAR(10), CAST(@Now AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATE), 23);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @LotsDone INT = 0, @ContribDone INT = 0, @RejectDone INT = 0, @NotesDone INT = 0;

BEGIN TRANSACTION;
BEGIN TRY

    -- ---- 1. The correction record, field by field (mirrors Lot_Update's writes) ----
    INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
    SELECT s.LotId, v.AttributeName, v.OldValue, v.NewValue, @AppUserId, NULL, @Now
    FROM #S s
    CROSS APPLY (VALUES
        (N'ItemId',       s.OldPart + N' (Id ' + CAST(s.OldItemId AS NVARCHAR(20)) + N')',
                          s.NewPart + N' (Id ' + CAST(s.NewItemId AS NVARCHAR(20)) + N')'),
        (N'ToolId',       @FromDieName + N' (Id ' + CAST(@FromToolId AS NVARCHAR(20)) + N')',
                          @ToDieName   + N' (Id ' + CAST(@ToToolId   AS NVARCHAR(20)) + N')'),
        (N'ToolCavityId', s.CavityCode + N' (Id ' + CAST(s.OldCavityId AS NVARCHAR(20)) + N')',
                          s.CavityCode + N' (Id ' + CAST(s.NewCavityId AS NVARCHAR(20)) + N')')
    ) v (AttributeName, OldValue, NewValue)
    WHERE v.AttributeName <> N'ItemId' OR s.OldItemId <> s.NewItemId;

    -- ---- 2. The LOT itself. The ToolId predicate makes a re-run a no-op. ----
    UPDATE l
    SET l.ItemId = s.NewItemId, l.ToolId = @ToToolId, l.ToolCavityId = s.NewCavityId,
        l.UpdatedAt = @Now, l.UpdatedByUserId = @AppUserId
    FROM Lots.Lot l
    INNER JOIN #S s ON s.LotId = l.Id
    WHERE l.ToolId = @FromToolId;
    SET @LotsDone = @@ROWCOUNT;
    IF @LotsDone <> (SELECT COUNT(*) FROM #S)
        RAISERROR(N'Expected to relabel %d LOTs but updated a different number -- something changed underneath. Rolled back.', 16, 1, @LotsDone);

    -- ---- 3. Die-cast rows that hang off those LOTs ----
    UPDATE c SET c.ToolCavityId = s.NewCavityId
    FROM Workorder.DieCastContribution c
    INNER JOIN #S s ON s.LotId = c.LotId
    WHERE c.ToolCavityId = s.OldCavityId;
    SET @ContribDone = @@ROWCOUNT;

    UPDATE r SET r.ItemId = s.NewItemId, r.ToolId = @ToToolId,
                 r.ToolCavityId = CASE WHEN r.ToolCavityId = s.OldCavityId THEN s.NewCavityId ELSE r.ToolCavityId END
    FROM Workorder.RejectEvent r
    INNER JOIN #S s ON s.LotId = r.LotId
    WHERE r.ToolId = @FromToolId;
    SET @RejectDone = @@ROWCOUNT;

    -- ---- 4. One audit row and one note per LOT ----
    DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @OldPart NVARCHAR(100), @NewPart NVARCHAR(100),
            @Cav NVARCHAR(10), @OldItemId BIGINT, @NewItemId BIGINT, @OldCavId BIGINT, @NewCavId BIGINT;
    DECLARE @Desc NVARCHAR(1000), @OldJson NVARCHAR(MAX), @NewJson NVARCHAR(MAX), @Note NVARCHAR(MAX),
            @Ctx NVARCHAR(MAX), @St BIT, @Msg NVARCHAR(500);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT LotId, LotName, OldPart, NewPart, CavityCode, OldItemId, NewItemId, OldCavityId, NewCavityId
        FROM #S ORDER BY LotName;
    OPEN cur;
    FETCH NEXT FROM cur INTO @LotId, @LotName, @OldPart, @NewPart, @Cav, @OldItemId, @NewItemId, @OldCavId, @NewCavId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Desc = Audit.ufn_TruncateActivity(
            @LotName + N' ' + Audit.ufn_MidDot() + N' Correction ' + Audit.ufn_MidDot()
            + N' ~Die ' + @FromDieName + N' -> ' + @ToDieName
            + N'; ~Part ' + @OldPart + N' -> ' + @NewPart
            + N'; cavity ' + @Cav + N'. ' + @Reason);

        SET @OldJson = (SELECT
            JSON_QUERY((SELECT @OldItemId AS Id, @OldPart AS Code FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))       AS ItemId,
            JSON_QUERY((SELECT @FromToolId AS Id, @FromDieName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))  AS ToolId,
            JSON_QUERY((SELECT @OldCavId AS Id, @Cav AS Code FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS ToolCavityId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @NewJson = (SELECT
            JSON_QUERY((SELECT @NewItemId AS Id, @NewPart AS Code FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))       AS ItemId,
            JSON_QUERY((SELECT @ToToolId AS Id, @ToDieName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))      AS ToolId,
            JSON_QUERY((SELECT @NewCavId AS Id, @Cav AS Code FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS ToolCavityId,
            @Reason AS Reason, N'sql/scratch/2026-10-07_relabel_lots_cast_on_wrong_die.sql' AS Script
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = NULL, @LocationId = NULL,
            @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
            @LogSeverityCode = N'Info', @Description = @Desc, @OldValue = @OldJson, @NewValue = @NewJson;

        IF @HasNotes = 1
        BEGIN
            SET @Note = N'CORRECTION ' + @Today + N': this LOT was recorded as ' + @OldPart + N' on die '
                      + @FromDieName + N'. It was actually cast on die ' + @ToDieName + N' as ' + @NewPart
                      + N' (cavity ' + @Cav + N'). Part, die and cavity corrected by data script. ' + @Reason;
            SET @Ctx = @NewJson;
            DELETE FROM @R;
            INSERT INTO @R EXEC Lots.LotNote_Add
                @LotId = @LotId, @NoteText = @Note, @AppUserId = @AppUserId,
                @TerminalLocationId = NULL, @WasElevated = 0, @ContextJson = @Ctx;
            SELECT @St = Status, @Msg = Message FROM @R;
            IF ISNULL(@St, 0) <> 1 RAISERROR(N'Note refused for LOT %s: %s', 16, 1, @LotName, @Msg);
            SET @NotesDone += 1;
        END

        FETCH NEXT FROM cur INTO @LotId, @LotName, @OldPart, @NewPart, @Cav, @OldItemId, @NewItemId, @OldCavId, @NewCavId;
    END
    CLOSE cur; DEALLOCATE cur;

    PRINT N'LOTs relabelled: ' + CAST(@LotsDone AS NVARCHAR(10))
        + N'   contribution rows: ' + CAST(@ContribDone AS NVARCHAR(10))
        + N'   reject rows: ' + CAST(@RejectDone AS NVARCHAR(10))
        + N'   notes: ' + CAST(@NotesDone AS NVARCHAR(10));

    -- ---- 5. What it looks like now (inside the transaction) ----
    SELECT N'4 AFTER' AS Section, l.LotName, sc.Code AS Status, l.PieceCount AS Pcs,
           i.PartNumber, i.Description, t.Name AS Die, tc.CavityCode AS Cavity,
           (SELECT COUNT(*) FROM Lots.LotAttributeChange a WHERE a.LotId = l.Id AND a.ChangedAt = @Now) AS CorrectionRows
    FROM #S s
    INNER JOIN Lots.Lot l            ON l.Id  = s.LotId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    INNER JOIN Tools.Tool t          ON t.Id  = l.ToolId
    LEFT  JOIN Tools.ToolCavity tc   ON tc.Id = l.ToolCavityId
    ORDER BY s.CreatedEt;

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
