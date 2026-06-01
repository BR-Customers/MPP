-- =============================================
-- Procedure:   Quality.QualitySpecVersion_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Marks a published version as deprecated by setting DeprecatedAt =
--   SYSUTCDATETIME(). The version is no longer returned by
--   _GetActiveForSpec but remains in history and continues to fulfill
--   FK constraints from production records. Rejects if the version
--   is not published or is already deprecated.
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpecVersion
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention: SUBJECT . CATEGORY
--                       . ACTION narrative Description
--                       (<PN> . Quality Spec "<Name>" v<N> . Deprecated).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpecVersion_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Get version state
        -- ====================
        DECLARE @ExistingPublishedAt  DATETIME2(3);
        DECLARE @ExistingDeprecatedAt DATETIME2(3);
        DECLARE @VersionNumber        INT;
        DECLARE @QualitySpecId        BIGINT;
        DECLARE @RowExists            BIT = 0;

        SELECT @ExistingPublishedAt  = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt,
               @VersionNumber        = VersionNumber,
               @QualitySpecId        = QualitySpecId,
               @RowExists            = 1
        FROM Quality.QualitySpecVersion WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Version not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Version is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NULL
        BEGIN
            SET @Message = N'Cannot deprecate a Draft version. Delete it instead or publish first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative (built from PRE-mutation state) =====

        -- Subject resolution: spec name via QualitySpecId; PartNumber via spec
        -- ItemId (PN prefix present only when ItemId resolves).
        DECLARE @SpecName   NVARCHAR(200);
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        SELECT @SpecName   = qs.Name,
               @PartNumber = i.PartNumber,
               @ItemDesc   = i.Description
        FROM Quality.QualitySpec qs
        LEFT JOIN Parts.Item i ON i.Id = qs.ItemId
        WHERE qs.Id = @QualitySpecId;

        DECLARE @Subject NVARCHAR(600) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber
                      + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END
                      + N' ' + Audit.ufn_MidDot() + N' '
                 ELSE N'' END;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N'Quality Spec "' + @SpecName + N'" v' +
            CAST(@VersionNumber AS NVARCHAR(10)) + N' ' + Audit.ufn_MidDot() + N' Deprecated';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Quality.QualitySpecVersion SET
            DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpecVersion',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Warning',
            @Description       = @Activity,
            @OldValue          = N'{"DeprecatedAt":null}',
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Quality spec version ' + CAST(@VersionNumber AS NVARCHAR(10)) +
                       N' deprecated successfully.';
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'QualitySpecVersion',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
