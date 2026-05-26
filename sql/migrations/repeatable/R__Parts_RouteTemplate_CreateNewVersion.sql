-- =============================================
-- Procedure:   Parts.RouteTemplate_CreateNewVersion
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Clone-to-modify: creates a new RouteTemplate row for the same Item as
--   @ParentRouteTemplateId, with VersionNumber = MAX(siblings) + 1. The
--   Name is copied from the parent; EffectiveFrom is @EffectiveFrom or
--   SYSUTCDATETIME(). All steps (OperationTemplateId, SequenceNumber,
--   IsRequired, Description) are copied from the parent into the new
--   RouteTemplateId.
--
--   The parent row is left untouched — engineering can deprecate it
--   manually via _Deprecate. Steps from the parent are not modified.
--
--   Single-Draft-per-Item: rejects when an active Draft already exists
--   for the parent's ItemId. Engineering must Publish or DiscardDraft
--   the open Draft before creating another.
--
-- Parameters (input):
--   @ParentRouteTemplateId BIGINT - The source version to clone. Required.
--   @EffectiveFrom DATETIME2 NULL - When the new version becomes active.
--                                    NULL → uses SYSUTCDATETIME().
--   @AppUserId BIGINT             - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-20 - 3.0 - Single-Draft-per-Item guard. Rejects when an
--                      active Draft (PublishedAt NULL, DeprecatedAt NULL)
--                      already exists for the parent's ItemId.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId BIGINT,
    @EffectiveFrom         DATETIME2     = NULL,
    @AppUserId             BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_CreateNewVersion';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ParentRouteTemplateId AS ParentRouteTemplateId,
                @EffectiveFrom AS EffectiveFrom
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ParentRouteTemplateId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @ParentRouteTemplateId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Parent must exist (can be deprecated — cloning a retired version is allowed)
        IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE Id = @ParentRouteTemplateId)
        BEGIN
            SET @Message = N'Parent RouteTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @ParentRouteTemplateId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Single-Draft-per-Item guard. Resolve the parent's ItemId, then
        -- reject if any active Draft already exists for that Item.
        DECLARE @ParentItemId BIGINT;
        SELECT @ParentItemId = ItemId
        FROM Parts.RouteTemplate
        WHERE Id = @ParentRouteTemplateId;

        IF EXISTS (
            SELECT 1 FROM Parts.RouteTemplate
            WHERE ItemId = @ParentItemId
              AND PublishedAt IS NULL
              AND DeprecatedAt IS NULL
        )
        BEGIN
            SET @Message = N'A Draft for this Item already exists. Publish or discard it before creating another.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @ParentRouteTemplateId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @EffFrom DATETIME2(3) = ISNULL(@EffectiveFrom, SYSUTCDATETIME());

        BEGIN TRANSACTION;

        -- Capture the parent's Name (ItemId already resolved above)
        DECLARE @ParentName NVARCHAR(200);
        SELECT @ParentName = Name
        FROM Parts.RouteTemplate
        WHERE Id = @ParentRouteTemplateId;

        -- Compute the next VersionNumber among siblings for this Item
        DECLARE @NextVersion INT;
        SELECT @NextVersion = ISNULL(MAX(VersionNumber), 0) + 1
        FROM Parts.RouteTemplate
        WHERE ItemId = @ParentItemId;

        -- Insert the clone header
        INSERT INTO Parts.RouteTemplate
            (ItemId, VersionNumber, Name, EffectiveFrom, CreatedByUserId, CreatedAt)
        VALUES
            (@ParentItemId, @NextVersion, @ParentName, @EffFrom, @AppUserId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Copy parent's steps into the new RouteTemplateId
        INSERT INTO Parts.RouteStep
            (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
        SELECT
            @NewId, OperationTemplateId, SequenceNumber, IsRequired, Description
        FROM Parts.RouteStep
        WHERE RouteTemplateId = @ParentRouteTemplateId;

        DECLARE @StepCount INT = @@ROWCOUNT;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'RouteTemplate cloned from parent as new version.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'New RouteTemplate version created (' +
                       CAST(@StepCount AS NVARCHAR(10)) + N' step(s) copied).';
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @ParentRouteTemplateId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
