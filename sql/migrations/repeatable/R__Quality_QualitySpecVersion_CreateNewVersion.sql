-- =============================================
-- Procedure:   Quality.QualitySpecVersion_CreateNewVersion
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Creates a new Draft version by cloning an existing version.
--   Copies all QualitySpecAttribute rows from the source version
--   to the new version with VersionNumber = MAX(siblings) + 1.
--   The new version starts as Draft (PublishedAt = NULL).
--
-- Parameters (input):
--   @SourceVersionId BIGINT - Required. The version to clone.
--   @EffectiveFrom DATETIME2(3) NULL - When this version becomes active.
--                                       NULL → uses SYSUTCDATETIME().
--   @AppUserId BIGINT - Required for audit and CreatedByUserId.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpecVersion, Quality.QualitySpecAttribute
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Quality Spec Config Tool: clone UomId + readable audit
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_CreateNewVersion
    @SourceVersionId BIGINT,
    @EffectiveFrom   DATETIME2(3)  = NULL,
    @AppUserId       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpecVersion_CreateNewVersion';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @SourceVersionId AS SourceVersionId, @EffectiveFrom AS EffectiveFrom
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @SourceVersionId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Get source version info
        -- ====================
        DECLARE @QualitySpecId BIGINT;
        DECLARE @SourceExists  BIT = 0;

        SELECT @QualitySpecId = QualitySpecId,
               @SourceExists  = 1
        FROM Quality.QualitySpecVersion WHERE Id = @SourceVersionId;

        IF @SourceExists = 0
        BEGIN
            SET @Message = N'Source version not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Check for existing draft
        -- ====================
        IF EXISTS (SELECT 1 FROM Quality.QualitySpecVersion
                   WHERE QualitySpecId = @QualitySpecId AND PublishedAt IS NULL)
        BEGIN
            SET @Message = N'A Draft version already exists for this spec. Publish or delete it first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Calculate new version number
        -- ====================
        DECLARE @NewVersionNumber INT = (
            SELECT ISNULL(MAX(VersionNumber), 0) + 1
            FROM Quality.QualitySpecVersion
            WHERE QualitySpecId = @QualitySpecId
        );

        DECLARE @EffFrom DATETIME2(3) = ISNULL(@EffectiveFrom, SYSUTCDATETIME());

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Quality.QualitySpecVersion
            (QualitySpecId, VersionNumber, EffectiveFrom, CreatedByUserId, CreatedAt)
        VALUES
            (@QualitySpecId, @NewVersionNumber, @EffFrom, @AppUserId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Clone attributes from source version (carry both legacy Uom and new UomId)
        INSERT INTO Quality.QualitySpecAttribute
            (QualitySpecVersionId, AttributeName, DataType, Uom, UomId,
             TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
        SELECT
            @NewId, AttributeName, DataType, Uom, UomId,
            TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder
        FROM Quality.QualitySpecAttribute
        WHERE QualitySpecVersionId = @SourceVersionId
        ORDER BY SortOrder;

        DECLARE @AttrCount INT = @@ROWCOUNT;

        -- ===== Readable audit narrative (convention: SUBJECT · CATEGORY · ACTION) =====
        -- Subject's PartNumber prefix is present only when the spec is item-scoped.
        DECLARE @SpecName   NVARCHAR(200);
        DECLARE @PartNumber NVARCHAR(50);

        SELECT @SpecName   = qs.Name,
               @PartNumber = i.PartNumber
        FROM Quality.QualitySpec qs
        LEFT JOIN Parts.Item i ON i.Id = qs.ItemId
        WHERE qs.Id = @QualitySpecId;

        DECLARE @AuditDesc NVARCHAR(MAX) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber + N' ' + Audit.ufn_MidDot() + N' '
                 ELSE N'' END +
            N'Quality Spec "' + ISNULL(@SpecName, N'') + N'" v' +
            CAST(@NewVersionNumber AS NVARCHAR(10)) +
            N' (Draft) ' + Audit.ufn_MidDot() +
            N' Created (cloned from source; ' +
            CAST(@AttrCount AS NVARCHAR(10)) + N' attributes)';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@AuditDesc);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpecVersion',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Quality spec version ' + CAST(@NewVersionNumber AS NVARCHAR(10)) +
                       N' created (Draft, cloned ' + CAST(@AttrCount AS NVARCHAR(10)) + N' attributes).';
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'QualitySpecVersion',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
