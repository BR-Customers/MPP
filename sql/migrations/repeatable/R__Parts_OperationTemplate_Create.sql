-- =============================================
-- Procedure:   Parts.OperationTemplate_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Creates a brand-new OperationTemplate at VersionNumber = 1. The
--   (Code, VersionNumber) UNIQUE constraint ensures no conflict with
--   existing families.
--
--   NOTE: To create a subsequent version of an existing template (the
--   clone-to-modify workflow), call Parts.OperationTemplate_CreateNewVersion
--   instead -- it copies the parent row and its OperationTemplateField
--   junction rows into a new version atomically.
--
-- Parameters (input):
--   @Code NVARCHAR(20)             - Code for this operation family. Required.
--   @Name NVARCHAR(100)            - Required.
--   @OperationTypeId BIGINT        - FK -> Parts.OperationType (role). Required.
--   @Description NVARCHAR(500) NULL
--   @AppUserId BIGINT              - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-07-02 - 3.0 - AreaLocationId -> OperationTypeId (operation-type restructure)
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplate_Create
    @Code            NVARCHAR(20),
    @Name            NVARCHAR(100),
    @OperationTypeId BIGINT,
    @Description     NVARCHAR(500)  = NULL,
    @AppUserId       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplate_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Code AS Code, @Name AS Name,
                @OperationTypeId AS OperationTypeId, @Description AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Parameter validation
        IF @Code IS NULL OR @Name IS NULL OR @OperationTypeId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: OperationTypeId must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationType WHERE Id = @OperationTypeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: no existing family with this Code
        IF EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = @Code)
        BEGIN
            SET @Message = N'An OperationTemplate with this Code already exists. Use _CreateNewVersion to add a new version of the existing family.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Parts.OperationTemplate
            (Code, VersionNumber, Name, OperationTypeId, Description, CreatedAt)
        VALUES
            (@Code, 1, @Name, @OperationTypeId, @Description, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'OperationTemplate',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'OperationTemplate created (v1).',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'OperationTemplate created successfully.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
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
