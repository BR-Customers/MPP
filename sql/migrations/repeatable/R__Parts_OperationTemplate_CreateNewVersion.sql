-- =============================================
-- Procedure:   Parts.OperationTemplate_CreateNewVersion
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.0
--
-- Description:
--   Clone-to-modify: creates a new OperationTemplate row by copying all
--   fields from @ParentOperationTemplateId into a new row with
--   VersionNumber = parent.VersionNumber + 1. Also replicates the
--   parent's active OperationTemplateField rows into the new version.
--
--   Engineering's UI flow:
--     1. Open an existing template.
--     2. Click "New Version" — this proc runs, producing a clone.
--     3. Engineering edits the clone (name, area, description, field list)
--        via subsequent _Update / OperationTemplateField_Add/Remove calls.
--     4. The previous version remains intact. Historical RouteSteps that
--        referenced the prior Id continue to resolve correctly — production
--        traceability is preserved.
--
--   The new row starts un-deprecated (DeprecatedAt IS NULL). The parent
--   is NOT auto-deprecated — engineering decides when to retire it.
--
-- Parameters (input):
--   @ParentOperationTemplateId BIGINT - The source version to clone. Required.
--   @AppUserId BIGINT                 - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplate_CreateNewVersion
    @ParentOperationTemplateId BIGINT,
    @AppUserId                 BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplate_CreateNewVersion';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ParentOperationTemplateId AS ParentOperationTemplateId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ParentOperationTemplateId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @ParentOperationTemplateId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Parent must exist (can be deprecated — cloning a retired version
        -- to resurrect a variant is a legitimate workflow)
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @ParentOperationTemplateId)
        BEGIN
            SET @Message = N'Parent OperationTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'OperationTemplate',
                @EntityId = @ParentOperationTemplateId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        -- Compute the next VersionNumber for this Code family
        DECLARE @ParentCode NVARCHAR(20);
        SELECT @ParentCode = Code FROM Parts.OperationTemplate WHERE Id = @ParentOperationTemplateId;

        DECLARE @NextVersion INT;
        SELECT @NextVersion = ISNULL(MAX(VersionNumber), 0) + 1
        FROM Parts.OperationTemplate
        WHERE Code = @ParentCode;

        -- Insert the clone: same Code, Name, OperationTypeId, Description; new VersionNumber
        INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, Description, CreatedAt)
        SELECT Code, @NextVersion, Name, OperationTypeId, Description, SYSUTCDATETIME()
        FROM Parts.OperationTemplate
        WHERE Id = @ParentOperationTemplateId;

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Replicate active OperationTemplateField rows from parent to the clone
        INSERT INTO Parts.OperationTemplateField
            (OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt)
        SELECT @NewId, DataCollectionFieldId, IsRequired, SYSUTCDATETIME()
        FROM Parts.OperationTemplateField
        WHERE OperationTemplateId = @ParentOperationTemplateId
          AND DeprecatedAt IS NULL;

        DECLARE @FieldCount INT = @@ROWCOUNT;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'OperationTemplate',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'OperationTemplate cloned from parent as new version.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'New OperationTemplate version created (' +
                       CAST(@FieldCount AS NVARCHAR(10)) + N' field(s) copied).';
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
                @EntityId = @ParentOperationTemplateId, @LogEventTypeCode = N'Created',
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
