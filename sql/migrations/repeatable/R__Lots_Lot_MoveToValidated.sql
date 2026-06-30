-- ============================================================
-- Repeatable:  R__Lots_Lot_MoveToValidated.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (spec sec 4.2). The server-authoritative inbound
--              move -- the Movement Scan pattern's commit step. A *validated*
--              sibling of Lots.Lot_MoveTo: enforces, in addition to the B2
--              not-blocked guard, FDS-02-012 eligibility (Item must resolve at
--              the destination via Parts.v_EffectiveItemLocation, Direct U
--              BomDerived) and the OI-12 MaxParts lineside cap. The generic
--              Lot_MoveTo is left UNTOUCHED for non-scan callers (Sort Cage,
--              Area-resolution moves) so they are not over-constrained.
--
--              MaxParts NULL = uncapped (the uniform rule -- this is what keeps
--              Area-resolution Trim IN moves and uncapped Items unconstrained
--              without a tier special-case).
--
--              Flow (FDS-11-011 + Msg-3915): ALL rejecting validations run BEFORE
--              BEGIN TRANSACTION (this proc is captured via INSERT-EXEC by
--              callers/tests). The not-blocked guard + the move are INLINED
--              (mirrors of Lots.Lot_AssertNotBlocked and Lots.Lot_MoveTo) rather
--              than EXEC'd. CATCH is the only ROLLBACK site. No OUTPUT params;
--              every exit ends SELECT @Status, @Message. RAISERROR (not THROW).
--              Audit 'LotMoved' (Lot entity -> Lots.LotEventLog).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_MoveToValidated
    @LotId              BIGINT,
    @ToLocationId       BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_MoveToValidated';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @ToLocationId AS ToLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @FromLocationId BIGINT;
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;
    DECLARE @ItemId         BIGINT;
    DECLARE @PieceCount     INT;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @ToLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, ToLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. LOT existence + B2 not-blocked guard (INLINED mirror of Lot_AssertNotBlocked) ----
        SELECT @FromLocationId = l.CurrentLocationId,
               @ItemId         = l.ItemId,
               @PieceCount     = l.PieceCount,
               @StatusCode     = sc.Code,
               @StatusName     = sc.Name,
               @Blocks         = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot be moved.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. Destination existence ----
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @ToLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Destination location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ToLocationId = @FromLocationId
        BEGIN
            SET @Message = N'LOT is already at the destination location (no-op).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. Eligibility (FDS-02-012 / FDS-03-014 hierarchy cascade) ----
        -- Item must resolve at the destination Cell OR any ancestor tier
        -- (Cell -> WorkCenter -> Area -> Site), consistent with the dropdown + Lot_Create.
        IF NOT EXISTS (
            SELECT 1 FROM Parts.v_EffectiveItemLocation
            WHERE ItemId = @ItemId
              AND LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@ToLocationId)))
        BEGIN
            SET @Message = N'Item is not eligible at the destination location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 5. MaxParts cap (OI-12). NULL = uncapped. ----
        DECLARE @MaxParts INT = (SELECT MaxParts FROM Parts.Item WHERE Id = @ItemId);
        IF @MaxParts IS NOT NULL
        BEGIN
            DECLARE @Existing INT = (
                SELECT ISNULL(SUM(l2.PieceCount), 0)
                FROM Lots.Lot l2
                INNER JOIN Lots.LotStatusCode s2 ON s2.Id = l2.LotStatusId
                WHERE l2.CurrentLocationId = @ToLocationId AND l2.ItemId = @ItemId AND s2.Code <> N'Closed');
            IF @Existing + @PieceCount > @MaxParts
            BEGIN
                SET @Message = N'Move would exceed Item MaxParts cap of ' + CAST(@MaxParts AS NVARCHAR(20))
                             + N' at the destination (' + CAST(@Existing AS NVARCHAR(20)) + N' existing + '
                             + CAST(@PieceCount AS NVARCHAR(20)) + N' incoming).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- ===== Mutation (atomic) -- INLINED mirror of Lots.Lot_MoveTo =====
        DECLARE @LotName  NVARCHAR(50)  = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @FromName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @FromLocationId);
        DECLARE @ToName   NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @ToLocationId);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @FromLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @ToLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Movement ' + Audit.ufn_MidDot()
            + N' ' + ISNULL(@FromName, N'(none)') + NCHAR(8594) + @ToName;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        UPDATE Lots.Lot
        SET CurrentLocationId = @ToLocationId,
            UpdatedAt         = SYSUTCDATETIME(),
            UpdatedByUserId   = @AppUserId
        WHERE Id = @LotId;

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@LotId, @FromLocationId, @ToLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @ToLocationId,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'LotMoved',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT moved to ' + @ToName + N'.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
