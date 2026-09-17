-- =============================================
-- Procedure:   Tools.Tool_CorrectShotCount
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
--
-- Description:
--   Sets a die's lifetime shot count to the value the die manager typed
--   on the Config Tool Tools screen (cutover entry or correction). Spec
--   docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md.
--
--   Mirrors the shift-reconcile increment in
--   Workorder.DieCastShiftOutput_Record (ShotCount = ShotCount + delta,
--   row-locked) with two differences: the delta may be negative, and it
--   touches ONLY Tools.Tool.ShotCount. It writes no
--   Workorder.DieCastContribution row and moves no watermark -- those rows
--   are the per-shift press-counter chain and drive basket crediting; a
--   lifetime die count is not a press reading.
--
--   Stale guard: @ExpectedShotCount is the count the screen loaded. If a
--   shift output has landed since, the proc refuses rather than overwrite
--   shots recorded while the user was typing. Checked before the
--   transaction and again by the UPDATE's WHERE (a race inside the window
--   commits nothing and returns the same refusal).
--
--   A non-blank @Note is mandatory. The record of the correction is one
--   Audit.ConfigLog row: the note appears in Description (truncated at
--   500) and in full in NewValue.Note.
--
-- Parameters (input):
--   @Id BIGINT                 - Tool PK. Required.
--   @ShotCount INT             - The actual lifetime count. Required, >= 0.
--   @ExpectedShotCount INT     - Count the screen loaded. Required.
--   @Note NVARCHAR(500)        - Why. Required, non-blank.
--   @AppUserId BIGINT          - Required.
--
-- Result set:
--   Single row: Status, Message.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_CorrectShotCount
    @Id                BIGINT,
    @ShotCount         INT,
    @ExpectedShotCount INT,
    @Note              NVARCHAR(500) = NULL,
    @AppUserId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName  NVARCHAR(200) = N'Tools.Tool_CorrectShotCount';
    DECLARE @CleanNote NVARCHAR(500) = NULLIF(LTRIM(RTRIM(@Note)), N'');
    DECLARE @Params    NVARCHAR(MAX) =
        (SELECT @Id                AS Id,
                @ShotCount         AS ShotCount,
                @ExpectedShotCount AS ExpectedShotCount,
                @Note              AS Note
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Validation (all before BEGIN TRANSACTION)
        -- ====================
        IF @Id IS NULL OR @ShotCount IS NULL OR @ExpectedShotCount IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            GOTO Fail;
        END

        IF @CleanNote IS NULL
        BEGIN
            SET @Message = N'A note is required when changing the shot count.';
            GOTO Fail;
        END

        IF @ShotCount < 0
        BEGIN
            SET @Message = N'Shot count cannot be negative.';
            GOTO Fail;
        END

        DECLARE @ToolTypeCode NVARCHAR(50), @Code NVARCHAR(50),
                @Name NVARCHAR(100), @Current INT;

        SELECT @ToolTypeCode = tt.Code,
               @Code         = t.Code,
               @Name         = t.Name,
               @Current      = t.ShotCount
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @Id AND t.DeprecatedAt IS NULL;

        IF @ToolTypeCode IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            GOTO Fail;
        END

        IF @ToolTypeCode <> N'Die'
        BEGIN
            SET @Message = N'Shot count is only tracked for Die-type Tools.';
            GOTO Fail;
        END

        IF @ShotCount = @ExpectedShotCount
        BEGIN
            SET @Message = N'Shot count is unchanged.';
            GOTO Fail;
        END

        IF @Current <> @ExpectedShotCount
        BEGIN
            SET @Message = N'Shot count changed since this die was opened (now '
                         + CAST(@Current AS NVARCHAR(20)) + N'). Reload and re-enter.';
            GOTO Fail;
        END

        -- ====================
        -- Audit narrative
        -- ====================
        DECLARE @Delta  INT          = @ShotCount - @ExpectedShotCount;
        DECLARE @MidDot NVARCHAR(10) = Audit.ufn_MidDot();
        DECLARE @Dash   NVARCHAR(10) = NCHAR(8212);   -- em dash, ASCII-safe source
        DECLARE @Arrow  NVARCHAR(10) = NCHAR(8594);   -- right arrow, field-diff notation

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Code + N' ' + @Dash + N' ' + @Name
            + N' ' + @MidDot + N' Shot Count '
            + @MidDot + N' ' + FORMAT(@ExpectedShotCount, 'N0', 'en-US')
            + N' ' + @Arrow + N' ' + FORMAT(@ShotCount, 'N0', 'en-US')
            + N' ' + @MidDot + N' ' + @CleanNote);

        DECLARE @OldValue NVARCHAR(MAX) =
            (SELECT @ExpectedShotCount AS ShotCount
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) =
            (SELECT @ShotCount AS ShotCount, @Delta AS Delta, @CleanNote AS Note
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation
        -- ====================
        BEGIN TRANSACTION;

        -- Same shape as the shift-reconcile increment; the extra predicate
        -- makes a shift output that lands after the pre-check a no-op.
        UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
        SET ShotCount       = ShotCount + @Delta,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id AND ShotCount = @ExpectedShotCount;

        IF @@ROWCOUNT = 0
        BEGIN
            COMMIT TRANSACTION;   -- nothing was written; close cleanly (no ROLLBACK outside CATCH)
            SET @Message = N'Shot count changed since this die was opened. Reload and re-enter.';
            GOTO Fail;
        END

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Tool',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shot count updated.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
        RETURN;
    END CATCH

Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter
    -- branch can arrive here with @AppUserId NULL -- skip the log then.
    IF @AppUserId IS NOT NULL
        EXEC Audit.Audit_LogFailure
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
            @EntityId = @Id, @LogEventTypeCode = N'Updated',
            @FailureReason = @Message, @ProcedureName = @ProcName,
            @AttemptedParameters = @Params;
    SELECT @Status AS Status, @Message AS Message;
END;
GO
