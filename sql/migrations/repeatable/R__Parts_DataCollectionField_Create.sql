-- =============================================
-- Procedure:   Parts.DataCollectionField_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Creates a new DataCollectionField row. Validates required fields and Code uniqueness
--   (against active rows; deprecated Codes may be re-used).
--   Logs success to Audit.ConfigLog or failure to Audit.FailureLog.
--
-- Parameters (input):
--   @Code NVARCHAR(50)         - Unique code. Required.
--   @Name NVARCHAR(100)        - Display name. Required.
--   @Description NVARCHAR(500) - Optional description.
--   @AppUserId BIGINT          - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Parts.DataCollectionField
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation/business-rule failures: Status=0, Message set, Audit_LogFailure.
--   - CATCH handler: rollback, Status=0, Audit_LogFailure, then RAISERROR.
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
-- =============================================
CREATE OR ALTER PROCEDURE Parts.DataCollectionField_Create
    @Code        NVARCHAR(50),
    @Name        NVARCHAR(100),
    @Description NVARCHAR(500)  = NULL,
    @AppUserId   BIGINT,
    @DataTypeId  BIGINT         = NULL   -- migration 0023: FK -> Parts.DataCollectionFieldDataType. Defaults to 'String' when unspecified.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.DataCollectionField_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Code AS Code, @Name AS Name, @Description AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Parameter validation
        IF @Code IS NULL OR @Name IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'DataCollectionField',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: Code unique among active rows
        IF EXISTS (SELECT 1 FROM Parts.DataCollectionField WHERE Code = @Code AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'A DataCollectionField with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'DataCollectionField',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- DataTypeId (migration 0023, NOT NULL): default to 'String' when the caller
        -- omits it, then validate the FK BEFORE opening the transaction (a rejection
        -- here returns cleanly with no open txn -- a ROLLBACK inside a proc invoked via
        -- INSERT-EXEC would throw Msg 3915).
        IF @DataTypeId IS NULL
            SET @DataTypeId = (SELECT Id FROM Parts.DataCollectionFieldDataType WHERE Code = N'String');
        IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = @DataTypeId)
        BEGIN
            SET @Message = N'Invalid DataTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'DataCollectionField',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Parts.DataCollectionField (Code, Name, Description, DataTypeId, CreatedAt)
        VALUES (@Code, @Name, @Description, @DataTypeId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DataCollectionField',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'DataCollectionField created.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'DataCollectionField created successfully.';
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
                @LogEntityTypeCode   = N'DataCollectionField',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
