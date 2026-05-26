-- =============================================
-- Procedure:   Parts.RouteTemplate_Publish
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Flips a Draft RouteTemplate to Published by setting PublishedAt =
--   SYSUTCDATETIME(). Optionally overrides EffectiveFrom and Name in
--   the same transaction (Item Master Routes tab Publish surface lets
--   engineering tweak the publish-as-of date or rename at the last step).
--   One-way transition — once a route is published, it becomes immutable
--   (RouteStep mutations reject). To change a published route, use
--   _CreateNewVersion which creates a Draft clone.
--
--   Rejects if the route is already published, deprecated, or has zero
--   RouteStep rows (a published route with no steps is nonsensical).
--
-- Parameters (input):
--   @Id BIGINT                       - RouteTemplate.Id. Required.
--   @AppUserId BIGINT                - Required for audit.
--   @EffectiveFrom DATETIME2(3) NULL - Optional override applied before
--                                       PublishedAt is set. NULL preserves
--                                       the row's existing EffectiveFrom.
--   @Name NVARCHAR(200) NULL         - Optional Name override. NULL
--                                       preserves the row's existing Name.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-20 - 3.0 - Added optional @EffectiveFrom + @Name overrides
--                      and a zero-steps guard.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_Publish
    @Id            BIGINT,
    @AppUserId     BIGINT,
    @EffectiveFrom DATETIME2(3)  = NULL,
    @Name          NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_Publish';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id            AS Id,
                @EffectiveFrom AS EffectiveFrom,
                @Name          AS Name
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @ExistingPublishedAt DATETIME2(3);
        DECLARE @ExistingDeprecatedAt DATETIME2(3);
        DECLARE @RowExists BIT = 0;

        SELECT @ExistingPublishedAt = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt,
               @RowExists = 1
        FROM Parts.RouteTemplate WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'RouteTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot publish a deprecated RouteTemplate.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'RouteTemplate is already published.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Zero-steps guard: a published route with no steps is nonsensical.
        IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @Id)
        BEGIN
            SET @Message = N'Cannot publish: route has no steps.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        -- Apply optional overrides in the same UPDATE that flips PublishedAt.
        -- ISNULL preserves the existing column value when the override is NULL.
        UPDATE Parts.RouteTemplate
        SET PublishedAt   = SYSUTCDATETIME(),
            EffectiveFrom = ISNULL(@EffectiveFrom, EffectiveFrom),
            Name          = ISNULL(@Name, Name)
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'RouteTemplate published.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'RouteTemplate published successfully.';
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
