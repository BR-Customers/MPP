-- =============================================
-- Procedure:   Parts.OperationTemplateField_SetRequired
-- Author:      Blue Ridge Automation
-- Created:     2026-06-03
-- Version:     1.0
--
-- Description:
--   Updates the IsRequired flag on a single OperationTemplateField
--   junction row. Used by the Operation Templates Config screen's
--   field-table Required checkbox toggle.
--
--   Rejects if the junction row does not exist, is deprecated, or
--   belongs to a deprecated OperationTemplate (engineering should
--   not be flipping flags on retired template versions).
--
-- Parameters (input):
--   @Id         BIGINT - Parts.OperationTemplateField.Id. Required.
--   @IsRequired BIT    - New value. Required.
--   @AppUserId  BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Change Log:
--   2026-06-03 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplateField_SetRequired
    @Id         BIGINT,
    @IsRequired BIT,
    @AppUserId  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplateField_SetRequired';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @IsRequired AS IsRequired
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @IsRequired IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OpTemplateField',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @CurrentIsRequired BIT;
        DECLARE @TemplateId BIGINT;
        SELECT @CurrentIsRequired = otf.IsRequired,
               @TemplateId        = otf.OperationTemplateId
        FROM Parts.OperationTemplateField otf
        WHERE otf.Id = @Id
          AND otf.DeprecatedAt IS NULL;

        IF @TemplateId IS NULL
        BEGIN
            SET @Message = N'OperationTemplateField not found or already removed.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OpTemplateField',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate
                       WHERE Id = @TemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'OperationTemplate is deprecated; cannot edit its fields.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OpTemplateField',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- No-op if value isn't changing -- still succeeds, but skips audit noise.
        IF @CurrentIsRequired = @IsRequired
        BEGIN
            SET @Status  = 1;
            SET @Message = N'No change (already at requested value).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE Parts.OperationTemplateField
        SET IsRequired = @IsRequired
        WHERE Id = @Id;

        DECLARE @OldValueJson NVARCHAR(MAX) =
            (SELECT @CurrentIsRequired AS IsRequired FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValueJson NVARCHAR(MAX) =
            (SELECT @IsRequired AS IsRequired FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'OpTemplateField',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'OperationTemplateField IsRequired toggled.',
            @OldValue          = @OldValueJson,
            @NewValue          = @NewValueJson;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'OperationTemplateField IsRequired updated.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OpTemplateField',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
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
