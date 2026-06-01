-- =============================================
-- Procedure:   Quality.QualitySpec_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Creates a new QualitySpec header. This is a lightweight parent
--   record that groups versioned specifications. The spec starts
--   empty — use QualitySpecVersion_Create to add the first version.
--
--   A spec can be scoped to an Item, OperationTemplate, both, or
--   neither (general-purpose spec).
--
-- Parameters (input):
--   @Name NVARCHAR(200) - Required.
--   @ItemId BIGINT NULL - Optional. Must be active if provided.
--   @OperationTemplateId BIGINT NULL - Optional. Must be active if provided.
--   @Description NVARCHAR(500) NULL - Optional.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpec, Parts.Item, Parts.OperationTemplate
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention: SUBJECT . CATEGORY
--                       . ACTION narrative Description
--                       (<PN — Desc> . Quality Spec "<Name>" . Created) +
--                       resolved-FK NewValue JSON (Item / OperationTemplate
--                       {Id, Code/PartNumber, Name/Description}).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpec_Create
    @Name                NVARCHAR(200),
    @ItemId              BIGINT         = NULL,
    @OperationTemplateId BIGINT         = NULL,
    @Description         NVARCHAR(500)  = NULL,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpec_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Name AS Name, @ItemId AS ItemId,
                @OperationTemplateId AS OperationTemplateId, @Description AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Name IS NULL OR LTRIM(RTRIM(@Name)) = N'' OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- FK existence checks
        -- ====================
        IF @ItemId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ItemId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @OperationTemplateId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationTemplateId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Quality.QualitySpec
            (Name, ItemId, OperationTemplateId, Description, CreatedAt)
        VALUES
            (LTRIM(RTRIM(@Name)), @ItemId, @OperationTemplateId, @Description, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ===== Audit narrative + resolved JSON =====

        -- Subject resolution (convention SUBJECT): Item PartNumber [- Description]
        -- PN prefix present only when ItemId resolves.
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        IF @ItemId IS NOT NULL
            SELECT @PartNumber = PartNumber, @ItemDesc = Description
            FROM Parts.Item WHERE Id = @ItemId;

        DECLARE @Subject NVARCHAR(600) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber
                      + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END
                      + N' ' + Audit.ufn_MidDot() + N' '
                 ELSE N'' END;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N'Quality Spec "' + LTRIM(RTRIM(@Name)) + N'" ' +
            Audit.ufn_MidDot() + N' Created';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-FK NewValue JSON
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                @NewId AS Id,
                LTRIM(RTRIM(@Name)) AS Name,
                @Description AS Description,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                 FROM Parts.Item i WHERE i.Id = @ItemId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Item,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                 FROM Parts.OperationTemplate ot WHERE ot.Id = @OperationTemplateId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS OperationTemplate
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpec',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Quality specification created successfully. Add version with QualitySpecVersion_Create.';
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
                @LogEntityTypeCode   = N'QualitySpec',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow failure-log errors to avoid masking the original error
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
