-- =============================================
-- Procedure:   Parts.OperationTemplate_DiscardDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-08-07
-- Version:     1.0
--
-- Description:
--   Hard-deletes an unpublished Draft OperationTemplate plus all of its
--   OperationTemplateField children. Only accepts active Drafts -- rejects rows
--   whose PublishedAt IS NOT NULL (cannot discard a Published template; use
--   Deprecate) or whose DeprecatedAt IS NOT NULL.
--
--   Drafts are private to engineering until Published, never resolved into
--   execution (the route-role resolver gates on PublishedAt IS NOT NULL), so a
--   hard delete that reclaims the VersionNumber slot is safe. Mirrors
--   R__Parts_RouteTemplate_DiscardDraft.sql.
--
--   Captures a full pre-state JSON snapshot (header + fields) into the audit
--   row's OldValue before deletion.
--
-- Parameters (input):
--   @Id BIGINT        - Required. Must be an active Draft OperationTemplate.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure. No NewId -- entity is gone.
--
-- Change Log:
--   2026-08-07 - 1.0 - Initial version (FAT-OQ-030). Mirrors
--                       R__Parts_RouteTemplate_DiscardDraft.sql.
--   2026-08-07 - 1.1 - Add in-use RouteStep guard (clean rejection instead of a
--                       FK Msg 547 in the CATCH) -- code review.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplate_DiscardDraft
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplate_DiscardDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ===== Pre-transaction rejections (no open txn; INSERT-EXEC / Msg-3915 rule) =====
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @ExistingPublishedAt  DATETIME2(3);
        DECLARE @ExistingDeprecatedAt DATETIME2(3);
        DECLARE @Code       NVARCHAR(20);
        DECLARE @VersionStr NVARCHAR(10);
        DECLARE @RowExists  BIT = 0;

        SELECT @ExistingPublishedAt  = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt,
               @Code                 = Code,
               @VersionStr           = CAST(VersionNumber AS NVARCHAR(10)),
               @RowExists            = 1
        FROM Parts.OperationTemplate WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'OperationTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot discard a Published OperationTemplate. Use Deprecate instead.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'OperationTemplate is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- In-use guard: reject cleanly rather than let the child DELETE hit a FK
        -- Msg 547 in the CATCH (a route can pin a Draft OT via RouteStep before it
        -- is published). Mirrors OperationTemplate_Deprecate's active-RouteStep guard.
        IF EXISTS (SELECT 1 FROM Parts.RouteStep WHERE OperationTemplateId = @Id)
        BEGIN
            SET @Message = N'Cannot discard: active RouteStep(s) reference this template.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====
        DECLARE @FieldCount INT =
            (SELECT COUNT(*) FROM Parts.OperationTemplateField
             WHERE OperationTemplateId = @Id AND DeprecatedAt IS NULL);

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Code + N' v' + @VersionStr + N' (Draft) ' + Audit.ufn_MidDot() +
            N' Operation Template ' + Audit.ufn_MidDot() +
            N' Discarded; ' + CAST(@FieldCount AS NVARCHAR(10)) + N' field(s) discarded');

        -- OldValue: discarded snapshot (header + resolved-FK fields). NewValue NULL.
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.VersionNumber, ot.Name, ot.Description,
                        ot.PublishedAt, ot.DeprecatedAt, ot.CreatedAt,
                        JSON_QUERY((SELECT oty.Id, oty.Code, oty.Name
                                    FROM Parts.OperationType oty WHERE oty.Id = ot.OperationTypeId
                                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationType
                 FROM Parts.OperationTemplate ot WHERE ot.Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                      AS Header,
                JSON_QUERY(ISNULL((
                    SELECT otf.Id, otf.DataCollectionFieldId, otf.IsRequired
                    FROM Parts.OperationTemplateField otf
                    WHERE otf.OperationTemplateId = @Id
                      AND otf.DeprecatedAt IS NULL
                    ORDER BY otf.Id
                    FOR JSON PATH
                ), N'[]'))                                                   AS Fields
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        BEGIN TRANSACTION;

        DELETE FROM Parts.OperationTemplateField WHERE OperationTemplateId = @Id;
        DELETE FROM Parts.OperationTemplate      WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'OperationTemplate',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deleted',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
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
