-- =============================================
-- Procedure:   Tools.Tool_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.0
--
-- Description:
--   Retires a Tool: sets DeprecatedAt (archive / row lifecycle) AND moves
--   StatusCode to 'Retired' (business state) in one action, so the UI status
--   chip and dropdown reflect the retirement rather than the stale prior
--   status. The two columns stay independent everywhere else (other status
--   transitions go through Tool_UpdateStatus without deprecating); Retire is
--   the one action that drives both. Rejects if the Tool
--   has an active ToolAssignment (currently mounted on a Cell) — the
--   operator must Release it first. Rejects if active ToolAttributes
--   or ToolCavities exist — Tools with cavities register them once
--   and never unregister; deprecation of a Tool is a real end-of-life
--   event that should not leave orphaned cavity/attribute rows.
--   (Rows stay for historical reference; the filter is just active.)
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required.
--
-- Result set:
--   Single row: Status, Message.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolAssignment, Tools.ToolAttribute, Tools.ToolCavity
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @RetiredStatusId BIGINT =
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Retired');

    DECLARE @ProcName NVARCHAR(200) = N'Tools.Tool_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Tool not found or already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Active assignment blocks deprecation
        IF EXISTS (SELECT 1 FROM Tools.ToolAssignment
                   WHERE ToolId = @Id AND ReleasedAt IS NULL)
        BEGIN
            SET @Message = N'Cannot deprecate: Tool is currently assigned to a Cell. Release the assignment first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Capture prior status for the audit OldValue before we overwrite it.
        DECLARE @OldStatusCode NVARCHAR(20) =
            (SELECT sc.Code
             FROM Tools.Tool t
             JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
             WHERE t.Id = @Id);

        DECLARE @OldVal NVARCHAR(MAX) =
            (SELECT @OldStatusCode AS StatusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewVal NVARCHAR(MAX) =
            (SELECT @Id AS Id, N'Retired' AS StatusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        -- Retire = archive (DeprecatedAt) + business status Retired in one move.
        -- ISNULL guard: if the 'Retired' code is somehow absent, leave the
        -- existing (NOT NULL) status rather than nulling it.
        UPDATE Tools.Tool
        SET DeprecatedAt    = SYSUTCDATETIME(),
            StatusCodeId    = ISNULL(@RetiredStatusId, StatusCodeId),
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Tool',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = N'Tool retired (deprecated; status set to Retired).',
            @OldValue          = @OldVal,
            @NewValue          = @NewVal;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tool retired successfully.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
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
