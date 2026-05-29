-- =============================================
-- Procedure:   Quality.QualitySpecVersion_DiscardDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-05-29
-- Version:     1.0
--
-- Description:
--   Physically deletes a Draft QualitySpecVersion and all of its
--   QualitySpecAttribute children. Target must be Draft
--   (PublishedAt IS NULL AND DeprecatedAt IS NULL). Captures full
--   pre-delete state as OldValue in Audit.ConfigLog (attributes carry
--   resolved Uom {Id, Code, Name}) so the draft is forensically
--   reconstructable if needed.
--
--   Rejects published or deprecated versions (those are immutable; use
--   QualitySpecVersion_Deprecate for published ones).
--
-- Parameters (input):
--   @Id        BIGINT - Required. QualitySpecVersion Id.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpecVersion, Quality.QualitySpecAttribute,
--           Quality.QualitySpec, Parts.Item, Parts.Uom
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-05-29 - 1.0 - Initial. Audit-readability convention from day one:
--                       SUBJECT . CATEGORY . ACTION narrative Description
--                       (<PN> . Quality Spec "<Name>" v<N> (Draft) . Discarded)
--                       + resolved-FK OldValue (full pre-delete snapshot,
--                       attributes w/ resolved Uom); NewValue NULL.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_DiscardDraft
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpecVersion_DiscardDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @VersionNumber        INT          = NULL;
    DECLARE @QualitySpecId        BIGINT       = NULL;
    DECLARE @EffFrom              DATETIME2(3) = NULL;
    DECLARE @ExistingPublishedAt  DATETIME2(3) = NULL;
    DECLARE @ExistingDeprecatedAt DATETIME2(3) = NULL;
    DECLARE @OldValue             NVARCHAR(MAX);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Get version state
        -- ====================
        SELECT @VersionNumber        = VersionNumber,
               @QualitySpecId        = QualitySpecId,
               @EffFrom              = EffectiveFrom,
               @ExistingPublishedAt  = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt
        FROM Quality.QualitySpecVersion WHERE Id = @Id;

        IF @VersionNumber IS NULL
        BEGIN
            SET @Message = N'Version not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL OR @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot discard a published or deprecated version.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

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
            CAST(@VersionNumber AS NVARCHAR(10)) + N' (Draft) ' +
            Audit.ufn_MidDot() + N' Discarded';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Capture full pre-delete state (version header + attribute set with
        -- resolved Uom {Id, Code, Name}).
        SET @OldValue = (
            SELECT
                @Id AS Id,
                @QualitySpecId AS QualitySpecId,
                @VersionNumber AS VersionNumber,
                @EffFrom AS EffectiveFrom,
                JSON_QUERY((
                    SELECT
                        a.Id, a.AttributeName, a.DataType,
                        JSON_QUERY((SELECT u.Id, u.Code, u.Name
                         FROM Parts.Uom u WHERE u.Id = a.UomId
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Uom,
                        a.TargetValue, a.LowerLimit, a.UpperLimit,
                        a.IsRequired, a.SortOrder
                    FROM Quality.QualitySpecAttribute a
                    WHERE a.QualitySpecVersionId = @Id
                    ORDER BY a.SortOrder
                    FOR JSON PATH
                )) AS Attributes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        DELETE FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @Id;
        DELETE FROM Quality.QualitySpecVersion WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpecVersion',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deleted',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Draft version ' + CAST(@VersionNumber AS NVARCHAR(10)) +
                       N' discarded.';
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
                @LogEventTypeCode    = N'Deleted',
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
