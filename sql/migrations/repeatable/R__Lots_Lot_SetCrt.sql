-- ============================================================
-- Repeatable:  R__Lots_Lot_SetCrt.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-10-011/012). Activates the Controlled Run
--              Tag on a LOT (Lots.Lot.CrtActive 0 -> 1). A CRT-active LOT is
--              surfaced by Quality.Crt_GetRequiredInspections for the 200%
--              downstream inspection prompt.
--
--              Rules:
--                * LOT must exist and must NOT be Closed (a terminal LOT
--                  cannot enter a controlled run).
--                * Idempotence guard: setting an already-active CRT returns
--                  Status 0 with a clear message (no double-activate rows).
--                * AD elevation is the UI's FDS-04-007 concern -- the proc
--                  takes @AppUserId as attribution only.
--
--              Audit: entity 'Lot' / event 'CrtActivated' -> B7-routes to the
--              20-yr Lots.LotEventLog. Description: <LotName> . CRT . Activated.
--
--              FDS-11-011: all rejecting validations before BEGIN TRANSACTION;
--              CATCH is the only ROLLBACK site. Update-shaped terminal row:
--              Status, Message (no NewId).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_SetCrt
    @LotId              BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_SetCrt';
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
                    @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. LOT exists ----
        DECLARE @LotName    NVARCHAR(50);
        DECLARE @CrtActive  BIT;
        DECLARE @StatusCode NVARCHAR(20);
        SELECT @LotName = l.LotName, @CrtActive = l.CrtActive, @StatusCode = sc.Code
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. Closed LOTs cannot enter a controlled run ----
        IF @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT ' + @LotName + N' is Closed and cannot be placed on a Controlled Run Tag.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. Idempotence guard: already active ----
        IF @CrtActive = 1
        BEGIN
            SET @Message = N'CRT is already active on LOT ' + @LotName + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Lots.Lot
        SET CrtActive       = 1,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot() + N' Activated';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (SELECT CAST(0 AS BIT) AS CrtActive FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                CAST(1 AS BIT) AS CrtActive,
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
            @LogEventTypeCode   = N'CrtActivated',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'CRT activated on LOT ' + @LotName + N'.';
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
                @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
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
