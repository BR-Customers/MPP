-- ============================================================
-- Repeatable:  R__Quality_Crt_FlagMissedInspection.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-10-012). Flags a MISSED required CRT (200%)
--              inspection on a CRT-active LOT. Writes ONLY the MissedCrtInspect
--              audit row (entity 'Lot' -> B7-routes to the 20-yr
--              Lots.LotEventLog); there is NO table mutation -- the audit
--              stream IS the missed-inspection record, and the operation
--              re-run is procedural (v1 surfaces, does not gate).
--
--              Severity 'Warning' so the miss stands out in the LOT timeline.
--              Description: <LotName> . CRT . Missed inspection flagged.
--
--              FDS-11-011: all rejecting validations before BEGIN TRANSACTION;
--              CATCH is the only ROLLBACK site. Update-shaped terminal row:
--              Status, Message (no NewId -- nothing is created but the log).
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Crt_FlagMissedInspection
    @LotId              BIGINT,
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.Crt_FlagMissedInspection';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @Remarks AS Remarks,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'MissedCrtInspect',
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
                @EntityId = @LotId, @LogEventTypeCode = N'MissedCrtInspect',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. LOT must be CRT-active (a miss only means something on a controlled run) ----
        IF @CrtActive <> 1
        BEGIN
            SET @Message = N'LOT ' + @LotName + N' is not CRT-active; a missed CRT inspection cannot be flagged.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MissedCrtInspect',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit write (the only mutation; atomic) =====
        BEGIN TRANSACTION;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot()
            + N' Missed inspection flagged'
            + CASE WHEN @Remarks IS NOT NULL AND LTRIM(RTRIM(@Remarks)) <> N''
                   THEN N': ' + @Remarks ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                @Remarks AS Remarks,
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
            @LogEventTypeCode   = N'MissedCrtInspect',
            @LogSeverityCode    = N'Warning',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Missed CRT inspection flagged on LOT ' + @LotName + N'.';
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
                @EntityId = @LotId, @LogEventTypeCode = N'MissedCrtInspect',
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
