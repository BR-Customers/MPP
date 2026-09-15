-- ============================================================
-- 2026-09-14_close_stranded_basket.sql
--
-- ONE JOB: close basket 10627569, keeping its piece count as it stands.
--
-- It was left Open at DC1-M11 when DMO124 came off, so it appears on no screen
-- and cannot be reached. Releasing it makes it Good at storage, where it
-- rejoins its route and shows up in the Trim IN queue like any other basket.
--
-- @FinalPieceDelta = 0 and NO counter reading: the basket is settled where it
-- stands, not credited. A reading would credit (reading - cavity watermark),
-- and that watermark is press-scoped, so on a die that has moved presses it
-- invents castings.
--
-- @Commit = 0 (default) runs the release for real inside a transaction and
-- rolls it back, so the dry run exercises every guard instead of proving
-- nothing. Set @Commit = 1 to apply.
--
-- NOT IN SCOPE, deliberately. This LOT's PieceCount (2501) and
-- InventoryAvailable (2991) disagree by 490 -- drift from the manual Good->Open
-- reopen on 2026-09-11, which set one column without the other and left no
-- LotAttributeChange row. NO EXISTING PROC CAN REPAIR IT: Lot_RectifyPieceCount
-- and Lot_Update both refuse a no-op count change, and both also refuse an Open
-- LOT. Closing the basket does not require touching it. Tracked separately.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;   -- Lots.Lot carries a filtered index; DML needs this

DECLARE @LotName            NVARCHAR(50) = N'10627569';
DECLARE @AppUserInitials    NVARCHAR(10) = N'JGP';
DECLARE @TerminalLocationId BIGINT       = NULL;
DECLARE @Commit             BIT          = 0;

DECLARE @LotId BIGINT, @AppUserId BIGINT, @StatusCode NVARCHAR(50), @PieceCount INT;

SELECT @LotId = l.Id, @StatusCode = sc.Code, @PieceCount = l.PieceCount
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.LotName = @LotName;

SELECT @AppUserId = Id FROM Location.AppUser
WHERE Initials = @AppUserInitials AND DeprecatedAt IS NULL;

IF @LotId     IS NULL BEGIN RAISERROR(N'LOT %s not found.', 16, 1, @LotName); RETURN; END
IF @AppUserId IS NULL BEGIN RAISERROR(N'AppUser %s not found.', 16, 1, @AppUserInitials); RETURN; END
IF @StatusCode <> N'Open'
BEGIN RAISERROR(N'LOT is %s, not Open. Nothing to close.', 16, 1, @StatusCode); RETURN; END
IF @PieceCount <= 0
BEGIN RAISERROR(N'Basket is empty; Release needs a positive count.', 16, 1); RETURN; END

PRINT N'LOT ' + @LotName + N'  status ' + @StatusCode
    + N'  pieces ' + CAST(@PieceCount AS NVARCHAR(20))
    + N'   Commit: ' + CAST(@Commit AS NVARCHAR(1));

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @St BIT, @Msg NVARCHAR(500);

BEGIN TRANSACTION;
BEGIN TRY

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

    SELECT N'AFTER' AS Section, l.LotName, sc.Code AS Status,
           l.PieceCount, l.InventoryAvailable, loc.Code AS NowAt
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
