-- =============================================
-- Procedure:   Parts.OperationTemplate_Publish
-- Author:      Blue Ridge Automation
-- Created:     2026-08-07
-- Version:     1.0
--
-- Description:
--   Flips a Draft OperationTemplate to Published by setting PublishedAt =
--   SYSUTCDATETIME(). One-way transition: once published, a template resolves
--   into execution (die-cast / machining / assembly checkpoints via
--   OperationTemplate_GetForRouteRole, which gates on PublishedAt IS NOT NULL).
--   To change a published template, use _CreateNewVersion, which clones it into
--   a fresh Draft (VersionNumber+1).
--
--   Atomic single-Published invariant: when this version is published, any prior
--   version for the SAME Code that is currently Published-and-not-Deprecated is
--   stamped DeprecatedAt = SYSUTCDATETIME() in the same transaction. Enforces
--   "at most one Published-and-not-Deprecated OperationTemplate per Code" (same
--   model as Parts.RouteTemplate_Publish v3.2 / Parts.Bom_Publish v4.0). The
--   success message + audit narrative name the deprecated version(s).
--
--   Rejects if the template is already published or already deprecated.
--   (No zero-steps guard -- that is a route concept; a template with zero
--   data-collection fields is legitimate.)
--
-- Parameters (input):
--   @Id BIGINT        - OperationTemplate.Id. Required. Must be an active Draft.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Change Log:
--   2026-08-07 - 1.0 - Initial version (FAT-OQ-030). Mirrors
--                       R__Parts_RouteTemplate_Publish.sql, adapted for
--                       OperationTemplate (Code-based single-Published invariant;
--                       no EffectiveFrom/Name overrides; no zero-steps guard).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplate_Publish
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplate_Publish';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ===== Pre-transaction rejections (no open txn; INSERT-EXEC / Msg-3915 rule) =====
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
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
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot publish a deprecated OperationTemplate.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'OperationTemplate is already published.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====
        -- Prior Published-and-not-Deprecated version(s) for this Code are
        -- auto-deprecated when this version publishes (single-Published invariant).
        -- Captured during the in-transaction UPDATE below so the narrative +
        -- success message can name them.
        DECLARE @DeprecatedVersions TABLE (VersionNumber INT);

        -- OldValue: pre-publish header + resolved-FK OperationType.
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT ot.Id, ot.Code, ot.VersionNumber, ot.Name, ot.Description,
                   ot.PublishedAt, ot.DeprecatedAt,
                   JSON_QUERY((SELECT oty.Id, oty.Code, oty.Name
                               FROM Parts.OperationType oty WHERE oty.Id = ot.OperationTypeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationType
            FROM Parts.OperationTemplate ot WHERE ot.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        BEGIN TRANSACTION;

        -- Single-Published invariant: deprecate any prior Published-and-not-
        -- Deprecated version for this Code as this version flips to Published.
        -- Set-based, so it also defensively cleans up stale multi-Published rows.
        UPDATE Parts.OperationTemplate
        SET DeprecatedAt = SYSUTCDATETIME()
        OUTPUT inserted.VersionNumber INTO @DeprecatedVersions
        WHERE Code = @Code
          AND Id <> @Id
          AND PublishedAt IS NOT NULL
          AND DeprecatedAt IS NULL;

        -- Flip this version to Published.
        UPDATE Parts.OperationTemplate
        SET PublishedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        -- "(deprecated v<N>[, v<M>])" clause for the audit narrative.
        DECLARE @DepClause NVARCHAR(200) = N'';
        IF EXISTS (SELECT 1 FROM @DeprecatedVersions)
        BEGIN
            SELECT @DepClause = N' (deprecated ' +
                STRING_AGG(N'v' + CAST(VersionNumber AS NVARCHAR(10)), N', ')
                    WITHIN GROUP (ORDER BY VersionNumber) + N')'
            FROM @DeprecatedVersions;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Code + N' v' + @VersionStr + N' ' + Audit.ufn_MidDot() +
            N' Operation Template ' + Audit.ufn_MidDot() +
            N' Published' + @DepClause);

        -- NewValue: published header + resolved-FK OperationType.
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT ot.Id, ot.Code, ot.VersionNumber, ot.Name, ot.Description,
                   ot.PublishedAt, ot.DeprecatedAt,
                   JSON_QUERY((SELECT oty.Id, oty.Code, oty.Name
                               FROM Parts.OperationType oty WHERE oty.Id = ot.OperationTypeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationType
            FROM Parts.OperationTemplate ot WHERE ot.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'OperationTemplate',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        DECLARE @DepSuffix NVARCHAR(200) = N'';
        IF EXISTS (SELECT 1 FROM @DeprecatedVersions)
        BEGIN
            SELECT @DepSuffix = N' Deprecated ' +
                STRING_AGG(N'v' + CAST(VersionNumber AS NVARCHAR(10)), N', ') + N'.'
            FROM @DeprecatedVersions;
        END
        SET @Message = N'Published v' + @VersionStr + N'.' + @DepSuffix;
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
