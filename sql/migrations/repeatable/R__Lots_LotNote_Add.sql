-- ============================================================
-- Repeatable:  R__Lots_LotNote_Add.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-06
-- Version:     1.0
-- Description: Writes one free-text note against a LOT (Lots.LotNote,
--              migration 0107). Append-only: there is no update or delete
--              sibling, on purpose.
--
--              Not a protected action. Any signed-in user may write a note on
--              any LOT in any status -- including Closed, where "why was this
--              closed short" is exactly the kind of thing worth recording.
--
--              The proc stamps the LOT snapshot (status, location, piece
--              count) ITSELF from Lots.Lot. The caller cannot supply it, so a
--              stale screen cannot record a state the LOT was not in.
--
--              @NoteText is NVARCHAR(MAX) so an over-long note is REJECTED
--              with a message instead of being silently truncated to 1000 by
--              parameter binding.
--
--              @ContextJson is evidence, not input: malformed JSON is wrapped
--              as {"Unparsed": "..."} rather than failing the note. Losing a
--              note because a context string would not parse is the wrong
--              trade.
--
--              No Audit.* rows -- the table is itself the attributed,
--              append-only record (see migration 0107 header).
--
--              FDS-11-011: no OUTPUT params; every exit path ends with
--              SELECT Status, Message, NewId. Single INSERT, so no explicit
--              transaction.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotNote_Add
    @LotId              BIGINT,
    @NoteText           NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    @WasElevated        BIT           = 0,
    @ContextJson        NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. Note text: present, and within the column ----
        DECLARE @Text NVARCHAR(MAX) = LTRIM(RTRIM(ISNULL(@NoteText, N'')));
        IF LEN(@Text) = 0
        BEGIN
            SET @Message = N'Type a note before adding it.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF LEN(@Text) > 1000
        BEGIN
            SET @Message = N'Note is too long (' + CAST(LEN(@Text) AS NVARCHAR(10))
                         + N' characters). The limit is 1000.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. User exists ----
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'User not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. LOT exists; read the snapshot ----
        DECLARE @LotName NVARCHAR(50), @LotStatusId BIGINT, @LotLocationId BIGINT, @LotPieceCount INT;
        SELECT @LotName = l.LotName, @LotStatusId = l.LotStatusId,
               @LotLocationId = l.CurrentLocationId, @LotPieceCount = l.PieceCount
        FROM Lots.Lot l
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Terminal, when supplied, must be a real Location ----
        IF @TerminalLocationId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @TerminalLocationId)
        BEGIN
            SET @Message = N'Terminal location not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. Context is evidence: never let it fail the note ----
        DECLARE @Context NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@ContextJson)), N'');
        IF @Context IS NOT NULL AND ISJSON(@Context) = 0
            SET @Context = (SELECT @Context AS Unparsed FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ===== Mutation =====
        INSERT INTO Lots.LotNote
            (LotId, NoteText, AppUserId, TerminalLocationId, WasElevated,
             LotStatusId, LotLocationId, LotPieceCount, ContextJson)
        VALUES
            (@LotId, @Text, @AppUserId, @TerminalLocationId, ISNULL(@WasElevated, 0),
             @LotStatusId, @LotLocationId, @LotPieceCount, @Context);

        SET @NewId   = SCOPE_IDENTITY();
        SET @Status  = 1;
        SET @Message = N'Note added to LOT ' + @LotName + N'.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 AND XACT_STATE() = -1
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
