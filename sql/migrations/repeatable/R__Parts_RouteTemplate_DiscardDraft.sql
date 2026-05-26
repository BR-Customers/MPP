-- =============================================
-- Procedure:   Parts.RouteTemplate_DiscardDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-05-20
-- Version:     1.0
--
-- Description:
--   Hard-deletes an unpublished Draft RouteTemplate plus all of its
--   RouteStep children. Only accepts active Drafts — rejects rows whose
--   PublishedAt is NOT NULL (cannot discard a Published route) or whose
--   DeprecatedAt is NOT NULL.
--
--   Drafts are private to engineering until Published, never referenced
--   by production tables, and never visible to operators. Hard-delete is
--   safe and reclaims the VersionNumber slot is acceptable.
--
--   Captures a full pre-state JSON snapshot (header + ordered steps) into
--   the audit row's OldValue before deletion, so the ConfigLog row can
--   reconstruct what was discarded.
--
-- Parameters (input):
--   @Id BIGINT        - Required. Must be an active Draft RouteTemplate.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure. No NewId — entity is gone.
--
-- Change Log:
--   2026-05-20 - 1.0 - Initial version (Phase 5 Routes versioning).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_DiscardDraft
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_DiscardDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @ExistingPublishedAt  DATETIME2(3);
        DECLARE @ExistingDeprecatedAt DATETIME2(3);
        DECLARE @RowExists BIT = 0;

        SELECT @ExistingPublishedAt  = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt,
               @RowExists            = 1
        FROM Parts.RouteTemplate WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'RouteTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot discard a Published RouteTemplate. Use Deprecate instead.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'RouteTemplate is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Capture OldValue snapshot (header + ordered steps) BEFORE the deletion
        DECLARE @HeaderJson NVARCHAR(MAX) =
            (SELECT ItemId, VersionNumber, Name, EffectiveFrom,
                    PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt
             FROM Parts.RouteTemplate WHERE Id = @Id
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @StepsJson NVARCHAR(MAX) =
            ISNULL((
                SELECT Id, SequenceNumber, OperationTemplateId,
                       IsRequired, Description
                FROM Parts.RouteStep
                WHERE RouteTemplateId = @Id
                ORDER BY SequenceNumber
                FOR JSON PATH
            ), N'[]');

        DECLARE @OldValue NVARCHAR(MAX) =
            N'{"header":' + @HeaderJson + N',"steps":' + @StepsJson + N'}';

        BEGIN TRANSACTION;

        DELETE FROM Parts.RouteStep    WHERE RouteTemplateId = @Id;
        DELETE FROM Parts.RouteTemplate WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deleted',
            @LogSeverityCode   = N'Info',
            @Description       = N'RouteTemplate Draft hard-deleted (DiscardDraft).',
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Draft discarded.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
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
