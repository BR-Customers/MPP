-- ============================================================
-- Repeatable:  R__Lots_LotPause_Resume.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Closes an open LOT-pause (OI-21 / FDS-05-038). Validates the pause
--              exists and is still open (rejects an already-resumed pause), sets
--              the resume columns (ResumedByUserId / ResumedAt / ResumedRemarks),
--              and audits 'LotResumed'. The resumer MAY differ from the original
--              pauser. Returns SELECT @Status, @Message.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params. The 'PauseEvent' entity routes audit to Audit.OperationLog.
--              RAISERROR (not THROW) in the nested CATCH with failure logging.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotPause_Resume
    @PauseEventId       BIGINT,
    @ResumedRemarks     NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.LotPause_Resume';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @PauseEventId AS PauseEventId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotId      BIGINT;
    DECLARE @LocationId BIGINT;
    DECLARE @IsResumed  BIT;

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @PauseEventId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (PauseEventId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                    @EntityId = @PauseEventId, @LogEventTypeCode = N'LotResumed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        SELECT @LotId      = LotId,
               @LocationId = LocationId,
               @IsResumed  = CASE WHEN ResumedAt IS NOT NULL THEN 1 ELSE 0 END
        FROM Lots.PauseEvent
        WHERE Id = @PauseEventId;

        IF @LotId IS NULL
        BEGIN
            SET @Message = N'Pause event not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = @PauseEventId, @LogEventTypeCode = N'LotResumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @IsResumed = 1
        BEGIN
            SET @Message = N'Pause is already resumed.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = @PauseEventId, @LogEventTypeCode = N'LotResumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- Mutation (atomic) ----
        DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Pause ' + Audit.ufn_MidDot()
            + N' Resumed at ' + (SELECT Code FROM Location.Location WHERE Id = @LocationId)
            + CASE WHEN @ResumedRemarks IS NOT NULL THEN N' (' + @ResumedRemarks + N')' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT l.Id, l.LotName AS Code FROM Lots.Lot l WHERE l.Id = @LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @LocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   @ResumedRemarks AS ResumedRemarks
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Lots.PauseEvent
        SET ResumedByUserId = @AppUserId,
            ResumedAt       = SYSUTCDATETIME(),
            ResumedRemarks  = @ResumedRemarks
        WHERE Id = @PauseEventId;

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LocationId,
            @LogEntityTypeCode  = N'PauseEvent',
            @EntityId           = @PauseEventId,
            @LogEventTypeCode   = N'LotResumed',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT pause resumed.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = @PauseEventId, @LogEventTypeCode = N'LotResumed',
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
