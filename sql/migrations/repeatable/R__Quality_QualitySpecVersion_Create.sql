-- =============================================
-- Procedure:   Quality.QualitySpecVersion_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Creates the first version (VersionNumber = 1) for a given
--   QualitySpec. Starts as Draft (PublishedAt = NULL) so engineering
--   can add/edit attributes before publishing. The version starts
--   empty — attributes are added via QualitySpecAttribute_Add.
--   For subsequent versions, use _CreateNewVersion.
--
-- Parameters (input):
--   @QualitySpecId BIGINT - Required. Parent spec must exist.
--   @EffectiveFrom DATETIME2(3) NULL - When this version becomes active.
--                                       NULL → uses SYSUTCDATETIME().
--   @AppUserId BIGINT - Required for audit and CreatedByUserId.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpec, Quality.QualitySpecVersion
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention: SUBJECT . CATEGORY
--                       . ACTION narrative Description
--                       (<PN> . Quality Spec "<Name>" v1 (Draft) . Created).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_Create
    @QualitySpecId BIGINT,
    @EffectiveFrom DATETIME2(3)  = NULL,
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpecVersion_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @QualitySpecId AS QualitySpecId, @EffectiveFrom AS EffectiveFrom
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @QualitySpecId IS NULL OR @AppUserId IS NULL
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
        -- FK existence checks
        -- ====================
        IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec WHERE Id = @QualitySpecId)
        BEGIN
            SET @Message = N'Quality specification not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================
        IF EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE QualitySpecId = @QualitySpecId)
        BEGIN
            SET @Message = N'A version already exists for this spec. Use _CreateNewVersion to add a new version.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @EffFrom DATETIME2(3) = ISNULL(@EffectiveFrom, SYSUTCDATETIME());

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Quality.QualitySpecVersion
            (QualitySpecId, VersionNumber, EffectiveFrom, CreatedByUserId, CreatedAt)
        VALUES
            (@QualitySpecId, 1, @EffFrom, @AppUserId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ===== Audit narrative + resolved JSON =====

        -- Subject resolution (convention SUBJECT): resolve spec via QualitySpecId,
        -- PartNumber via spec ItemId (PN prefix present only when ItemId resolves).
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
            @Subject + N'Quality Spec "' + @SpecName + N'" v1 (Draft) ' +
            Audit.ufn_MidDot() + N' Created';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                @NewId AS Id,
                @QualitySpecId AS QualitySpecId,
                1 AS VersionNumber,
                @EffFrom AS EffectiveFrom
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpecVersion',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Quality spec version created successfully (Draft — add attributes and call _Publish when ready).';
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
