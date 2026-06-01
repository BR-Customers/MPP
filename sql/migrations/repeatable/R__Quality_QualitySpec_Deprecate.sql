-- =============================================
-- Procedure:   Quality.QualitySpec_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-05-29
-- Version:     1.0
--
-- Description:
--   Soft-deletes a QualitySpec header (SET DeprecatedAt +
--   DeprecatedByUserId) and cascade-deprecates all of its
--   non-deprecated child versions in Quality.QualitySpecVersion.
--
--   Idempotent: returns Status=1 + "Already deprecated." when the
--   target spec is already deprecated. (Child versions are still
--   swept on a fresh deprecate, so a partially-deprecated state from
--   a manual edit self-heals on the first non-idempotent call.)
--
--   A spec may be scoped to an Item — when so, the resolved Item
--   PartNumber prefixes the audit narrative.
--
-- Parameters (input):
--   @QualitySpecId BIGINT - Required.
--   @AppUserId     BIGINT - Required for audit + DeprecatedByUserId.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   No NewId — this is a deprecate.
--
-- Dependencies:
--   Tables: Quality.QualitySpec, Quality.QualitySpecVersion, Parts.Item
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-05-29 - 1.0 - Initial version (audit-readability convention:
--                       <PartNumber> . Quality Spec "<Name>" . Deprecated
--                       narrative + resolved-FK OldValue snapshot,
--                       NewValue NULL per removal semantics).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpec_Deprecate
    @QualitySpecId BIGINT,
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpec_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @QualitySpecId AS QualitySpecId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @SpecName             NVARCHAR(200) = NULL;
    DECLARE @PartNumber           NVARCHAR(50)  = NULL;
    DECLARE @RowExists            BIT           = 0;
    DECLARE @ExistingDeprecatedAt DATETIME2(3)  = NULL;

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @QualitySpecId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @QualitySpecId, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Existence check
        -- ====================
        SELECT @SpecName             = qs.Name,
               @PartNumber           = pi.PartNumber,
               @ExistingDeprecatedAt = qs.DeprecatedAt,
               @RowExists            = 1
        FROM Quality.QualitySpec qs
        LEFT JOIN Parts.Item pi ON pi.Id = qs.ItemId
        WHERE qs.Id = @QualitySpecId;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Quality spec not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @QualitySpecId, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Idempotent — already deprecated
        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Status  = 1;
            SET @Message = N'Already deprecated.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Activity: <PartNumber> . Quality Spec "<Name>" . Deprecated
        -- PartNumber prefix only when the spec's ItemId resolves.
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber + N' ' + Audit.ufn_MidDot() + N' '
                 ELSE N''
            END
            + N'Quality Spec "' + @SpecName + N'" '
            + Audit.ufn_MidDot() + N' Deprecated';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- OldValue: resolved snapshot of the spec being removed; Item resolved
        -- as an FK sub-object via JSON_QUERY (bare aliased FOR JSON double-encodes).
        -- NewValue NULL per removal semantics.
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                qs.Id,
                qs.Name,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                            FROM Parts.Item i WHERE i.Id = qs.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item
            FROM Quality.QualitySpec qs
            WHERE qs.Id = @QualitySpecId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Quality.QualitySpec
        SET DeprecatedAt       = SYSUTCDATETIME(),
            DeprecatedByUserId = @AppUserId
        WHERE Id = @QualitySpecId AND DeprecatedAt IS NULL;

        -- Cascade-deprecate non-deprecated child versions.
        UPDATE Quality.QualitySpecVersion
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE QualitySpecId = @QualitySpecId AND DeprecatedAt IS NULL;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpec',
            @EntityId          = @QualitySpecId,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Quality spec deprecated.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @QualitySpecId, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow failure-log errors to avoid masking the original error
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
