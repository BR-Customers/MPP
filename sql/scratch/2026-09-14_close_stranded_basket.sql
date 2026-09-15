-- ============================================================
-- 2026-09-14_close_stranded_basket.sql
--
-- Closes out a die-cast basket left Open on a die that is no longer mounted,
-- so it stops being invisible WIP and rejoins its route.
--
-- Found by sql/scratch/2026-09-14_orphaned_basket_check.sql. On prod that is
-- basket 10627569 (DMO124 cavity c, 12245-6MA -0000) -- opened 09-09, credited
-- by three operators across three days while they were learning the die cast
-- screens, then left open when the die came off.
--
-- SAFE BY DEFAULT. @Mode = 'Inspect' and @Commit = 0 both do nothing:
--   * @Mode  = 'Inspect' (default) runs the preview and stops. No transaction.
--   * @Commit = 0        (default) runs the real work in a transaction and
--                        ROLLS BACK, reporting exactly what would change.
--                        It does not skip the statements -- a preview that
--                        skipped them would prove nothing.
--
-- Everything goes through the procs (Lot_RectifyPieceCount, DieCastLot_Release,
-- DieCastLot_Void), never a raw UPDATE, so the change carries full validation
-- and audit rows -- the discipline 2026-09-03_import_prod_tools_to_dev.sql used.
--
-- ------------------------------------------------------------
-- MODES
--   Inspect  Preview only. Start here.
--   Close    The castings are real. Optionally correct the count, then release
--            the basket to storage (Open -> Good), where it rejoins its route
--            and appears in the Trim IN queue. No pieces are invented: the
--            closing delta is fixed at 0 and no counter reading is read.
--   Void     Voids an ALREADY-EMPTY basket (Open -> Scrap). It cannot empty a
--            basket for you -- see the ordering note below.
--
-- ORDERING, and why it is not the obvious one.
--   Lots.Lot_RectifyPieceCount refuses any LOT whose status is Open, Closed, or
--   blocking (R__Lots_Lot_RectifyPieceCount.sql line 154). So the correction
--   CANNOT happen while the basket is still Open. Close therefore RELEASES
--   FIRST -- which makes the LOT Good at storage -- and rectifies after. The
--   release carries @FinalPieceDelta = 0, so nothing is credited in between and
--   the count the rectify then sets is the count that sticks.
--
--   The same guard is why Void only accepts a basket that is already empty:
--   zeroing it would need a rectify, and a rectify needs it not to be Open.
--   A non-empty basket that should be scrapped is a Close followed by a scrap
--   entry against the released LOT, not a Void.
--
-- @CorrectedPieceCount  The real counted quantity, when the floor has one.
--                       NULL keeps the current PieceCount.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;   -- Lots.Lot carries a filtered index; DML needs this

-- ------------------------------------------------------------
-- PARAMETERS
-- ------------------------------------------------------------
DECLARE @LotName             NVARCHAR(50)  = N'10627569';
DECLARE @Mode                NVARCHAR(20)  = N'Close';     -- Inspect | Close | Void
DECLARE @CorrectedPieceCount INT           = NULL;
DECLARE @Reason              NVARCHAR(500) = N'Close-out of a basket left Open when DMO124 came off DC1-M11. PieceCount 2501 confirmed correct (569 counted at the 2026-09-11 reopen, plus 1932 credited since). InventoryAvailable realigned from 2991 -- it had kept the pre-reopen total because the manual reopen set PieceCount without it.';
DECLARE @AppUserInitials     NVARCHAR(10)  = N'JGP';
DECLARE @TerminalLocationId  BIGINT        = NULL;
DECLARE @Commit              BIT           = 0;

-- ------------------------------------------------------------
-- RESOLVE
-- ------------------------------------------------------------
DECLARE @LotId BIGINT, @AppUserId BIGINT, @StatusCode NVARCHAR(50);
DECLARE @PieceCount INT, @InvAvail INT;

SELECT @LotId = l.Id, @StatusCode = sc.Code,
       @PieceCount = l.PieceCount, @InvAvail = l.InventoryAvailable
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.LotName = @LotName;

SELECT @AppUserId = Id FROM Location.AppUser
WHERE Initials = @AppUserInitials AND DeprecatedAt IS NULL;

IF @LotId IS NULL
BEGIN
    RAISERROR(N'LOT %s not found.', 16, 1, @LotName);
    RETURN;
END

PRINT N'--------------------------------------------------------';
PRINT N'LOT          : ' + @LotName + N'  (Id ' + CAST(@LotId AS NVARCHAR(20)) + N')';
PRINT N'Status       : ' + @StatusCode;
PRINT N'PieceCount   : ' + CAST(@PieceCount AS NVARCHAR(20));
PRINT N'InvAvailable : ' + CAST(@InvAvail   AS NVARCHAR(20));
IF @PieceCount <> @InvAvail
    PRINT N'  ** These disagree by ' + CAST(ABS(@InvAvail - @PieceCount) AS NVARCHAR(20))
        + N' pieces. Both are maintained together by every normal path, so'
        + N' something set one without the other -- see the attribute-change'
        + N' preview below. Lot_RectifyPieceCount sets BOTH and realigns them.';
PRINT N'Mode         : ' + @Mode + N'    Commit: ' + CAST(@Commit AS NVARCHAR(1));
PRINT N'--------------------------------------------------------';

-- ------------------------------------------------------------
-- 1. PREVIEW  (read-only, always runs)
-- ------------------------------------------------------------
SELECT N'1. Basket' AS Section, l.LotName, sc.Code AS Status,
       l.PieceCount, l.InventoryAvailable,
       l.InventoryAvailable - l.PieceCount AS Divergence,
       t.Code AS Die, tc.CavityCode AS Cav, i.PartNumber AS Part,
       loc.Code AS SittingAt, u.Initials AS OpenedBy,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedEt
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
LEFT  JOIN Tools.Tool         t   ON t.Id   = l.ToolId
LEFT  JOIN Tools.ToolCavity   tc  ON tc.Id  = l.ToolCavityId
LEFT  JOIN Parts.Item         i   ON i.Id   = l.ItemId
LEFT  JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
LEFT  JOIN Location.AppUser   u   ON u.Id   = l.CreatedByUserId
WHERE l.Id = @LotId;

SELECT N'2. Contributions' AS Section,
       CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt,
       c.PieceDelta, c.ShotCounterReading, lc.Code AS Press, u.Initials AS By_
FROM Workorder.DieCastContribution c
LEFT JOIN Location.Location lc ON lc.Id = c.CellLocationId
LEFT JOIN Location.AppUser  u  ON u.Id  = c.AppUserId
WHERE c.LotId = @LotId
ORDER BY c.EventAt;

SELECT N'2b. Contribution total' AS Section,
       SUM(c.PieceDelta) AS SumOfDeltas, @PieceCount AS LotPieceCount, @InvAvail AS LotInvAvailable
FROM Workorder.DieCastContribution c WHERE c.LotId = @LotId;

SELECT N'3. Scrap' AS Section, dc.Code, dc.Description, re.Quantity,
       CAST(re.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RecordedEt
FROM Workorder.RejectEvent re
INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
WHERE re.LotId = @LotId
ORDER BY re.RecordedAt;

-- where a PieceCount change that skipped InventoryAvailable would show up
SELECT N'4. Attribute changes' AS Section, ac.AttributeName, ac.OldValue, ac.NewValue,
       u.Initials AS By_,
       CAST(ac.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ChangedEt
FROM Lots.LotAttributeChange ac
LEFT JOIN Location.AppUser u ON u.Id = ac.ChangedByUserId
WHERE ac.LotId = @LotId
ORDER BY ac.ChangedAt;

SELECT N'5. Status history' AS Section, osc.Code AS FromStatus, nsc.Code AS ToStatus, sh.Reason,
       u.Initials AS By_,
       CAST(sh.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ChangedEt
FROM Lots.LotStatusHistory sh
LEFT JOIN Lots.LotStatusCode osc ON osc.Id = sh.OldStatusId
LEFT JOIN Lots.LotStatusCode nsc ON nsc.Id = sh.NewStatusId
LEFT JOIN Location.AppUser   u   ON u.Id   = sh.ChangedByUserId
WHERE sh.LotId = @LotId
ORDER BY sh.ChangedAt;

SELECT N'6. Movements' AS Section, fl.Code AS FromLoc, tl.Code AS ToLoc,
       CAST(m.MovedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS MovedEt
FROM Lots.LotMovement m
LEFT JOIN Location.Location fl ON fl.Id = m.FromLocationId
LEFT JOIN Location.Location tl ON tl.Id = m.ToLocationId
WHERE m.LotId = @LotId
ORDER BY m.MovedAt;

SELECT N'7. Children' AS Section, COUNT(*) AS DescendantEdges
FROM Lots.LotGenealogy g WHERE g.ParentLotId = @LotId;

IF @Mode = N'Inspect'
BEGIN
    PRINT N'Mode = Inspect. Nothing further run. Set @Mode to Close or Void when ready.';
    RETURN;
END

-- ------------------------------------------------------------
-- 2. GUARDS  (all abort BEFORE any transaction opens)
-- ------------------------------------------------------------
IF @Mode NOT IN (N'Close', N'Void')
BEGIN RAISERROR(N'@Mode must be Inspect, Close or Void.', 16, 1); RETURN; END

IF @StatusCode <> N'Open'
BEGIN RAISERROR(N'LOT is %s, not Open. Nothing to close.', 16, 1, @StatusCode); RETURN; END

IF @AppUserId IS NULL
BEGIN RAISERROR(N'AppUser %s not found or deprecated.', 16, 1, @AppUserInitials); RETURN; END

IF @CorrectedPieceCount IS NOT NULL AND @CorrectedPieceCount < 0
BEGIN RAISERROR(N'@CorrectedPieceCount cannot be negative.', 16, 1); RETURN; END

IF EXISTS (SELECT 1 FROM Lots.LotGenealogy WHERE ParentLotId = @LotId)
BEGIN RAISERROR(N'LOT has descendants. Stop and review before closing.', 16, 1); RETURN; END

IF @Mode = N'Close' AND ISNULL(@CorrectedPieceCount, @PieceCount) <= 0
BEGIN RAISERROR(N'Close needs a positive piece count. Use Void for an empty basket.', 16, 1); RETURN; END

-- Void cannot empty a basket: zeroing it needs a rectify, and a rectify refuses
-- an Open LOT. A non-empty basket that should be scrapped is a Close followed by
-- a scrap entry against the released LOT.
IF @Mode = N'Void' AND @PieceCount > 0
BEGIN
    RAISERROR(N'Void only accepts an empty basket; this one holds %d pieces. Use Close, then record scrap against the released LOT.', 16, 1, @PieceCount);
    RETURN;
END

-- ------------------------------------------------------------
-- 3. THE WORK  (transactional; rolled back unless @Commit = 1)
-- ------------------------------------------------------------
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @St BIT, @Msg NVARCHAR(500);
DECLARE @TargetCount INT = ISNULL(@CorrectedPieceCount, @PieceCount);
IF @Mode = N'Void' SET @TargetCount = 0;

BEGIN TRANSACTION;
BEGIN TRY

    -- 3a. Close it out FIRST. Rectify cannot touch an Open LOT (see the header),
    --     so the status has to move before the numbers can be corrected.
    IF @Mode = N'Close'
    BEGIN
        -- @FinalPieceDelta fixed at 0 and NO counter reading: this basket is
        -- being settled where it stands, not credited. Passing a reading would
        -- credit (reading - cavity watermark) and invent castings.
        DELETE FROM @R;
        INSERT INTO @R
        EXEC Lots.DieCastLot_Release
            @LotId              = @LotId,
            @StorageLocationId  = NULL,      -- resolves the well-known WHSE
            @FinalPieceDelta    = 0,
            @CounterReading     = NULL,
            @ScrapLinesJson     = NULL,
            @ShiftId            = NULL,
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId;

        SELECT @St = Status, @Msg = Message FROM @R;
        PRINT N'Release -> ' + CAST(@St AS NVARCHAR(1)) + N' : ' + ISNULL(@Msg, N'');
        IF @St = 0 BEGIN RAISERROR(N'Release refused: %s', 16, 1, @Msg); END
    END
    ELSE
    BEGIN
        DELETE FROM @R;
        INSERT INTO @R
        EXEC Lots.DieCastLot_Void
            @LotId              = @LotId,
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId;

        SELECT @St = Status, @Msg = Message FROM @R;
        PRINT N'Void -> ' + CAST(@St AS NVARCHAR(1)) + N' : ' + ISNULL(@Msg, N'');
        IF @St = 0 BEGIN RAISERROR(N'Void refused: %s', 16, 1, @Msg); END
    END

    -- 3b. Re-read: the release may have moved the numbers, and the rectify has
    --     to act on what is actually there now, not on what was there before.
    SELECT @PieceCount = PieceCount, @InvAvail = InventoryAvailable
    FROM Lots.Lot WHERE Id = @LotId;

    -- 3c. Correct the count, and/or realign the two columns. Runs on a Good LOT
    --     now, which the guard accepts. Lot_RectifyPieceCount writes PieceCount
    --     AND InventoryAvailable, so it is the repair for a divergence even when
    --     the count itself does not change.
    IF @Mode = N'Close' AND (@TargetCount <> @PieceCount OR @PieceCount <> @InvAvail)
    BEGIN
        DELETE FROM @R;
        INSERT INTO @R
        EXEC Lots.Lot_RectifyPieceCount
            @LotId              = @LotId,
            @NewPieceCount      = @TargetCount,
            @Reason             = @Reason,
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId;

        SELECT @St = Status, @Msg = Message FROM @R;
        PRINT N'Rectify -> ' + CAST(@St AS NVARCHAR(1)) + N' : ' + ISNULL(@Msg, N'');
        IF @St = 0 BEGIN RAISERROR(N'Rectify refused: %s', 16, 1, @Msg); END
    END
    ELSE PRINT N'Rectify -> skipped (count unchanged, columns already agree).';

    -- 3d. After-state, inside the transaction so the dry run shows it too.
    SELECT N'AFTER' AS Section, l.LotName, sc.Code AS Status,
           l.PieceCount, l.InventoryAvailable,
           l.InventoryAvailable - l.PieceCount AS Divergence,
           loc.Code AS NowAt
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    LEFT  JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
    WHERE l.Id = @LotId;

    IF @Commit = 1
    BEGIN
        COMMIT TRANSACTION;
        PRINT N'>>> COMMITTED.';
    END
    ELSE
    BEGIN
        ROLLBACK TRANSACTION;
        PRINT N'>>> DRY RUN -- rolled back. Nothing changed. Set @Commit = 1 to apply.';
    END
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @E NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT N'>>> FAILED and rolled back: ' + @E;
    RAISERROR(@E, 16, 1);
END CATCH
GO
