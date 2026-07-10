-- ============================================================
-- Repeatable:  R__Lots_Lot_ClearCrt.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-10-011/012). Clears the Controlled Run Tag
--              on a LOT (Lots.Lot.CrtActive 1 -> 0). Clearance is a
--              supervisor-elevated release -- the AD elevation is the UI's
--              FDS-04-007 concern; the proc takes @AppUserId as attribution.
--
--              Rules:
--                * LOT must exist (Closed LOTs MAY be cleared -- releasing a
--                  tag from a finished LOT is a bookkeeping correction).
--                * Idempotence guard: clearing an already-clear flag returns
--                  Status 0 with a clear message.
--
--              Audit: entity 'Lot' / event 'CrtCleared' -> B7-routes to the
--              20-yr Lots.LotEventLog. Description: <LotName> . CRT . Cleared.
--
--              FDS-11-011: all rejecting validations before BEGIN TRANSACTION;
--              CATCH is the only ROLLBACK site. Update-shaped terminal row:
--              Status, Message (no NewId).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_ClearCrt
    @LotId              BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_ClearCrt';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'CrtCleared',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. LOT exists ----
        DECLARE @LotName   NVARCHAR(50);
        DECLARE @CrtActive BIT;
        SELECT @LotName = LotName, @CrtActive = CrtActive
        FROM Lots.Lot WHERE Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'CrtCleared',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. Idempotence guard: not active ----
        IF @CrtActive = 0
        BEGIN
            SET @Message = N'CRT is not active on LOT ' + @LotName + N'; nothing to clear.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'CrtCleared',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Lots.Lot
        SET CrtActive       = 0,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot() + N' Cleared';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (SELECT CAST(1 AS BIT) AS CrtActive FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                CAST(0 AS BIT) AS CrtActive,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = @LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'CrtCleared',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'CRT cleared on LOT ' + @LotName + N'.';
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
                @EntityId = @LotId, @LogEventTypeCode = N'CrtCleared',
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
