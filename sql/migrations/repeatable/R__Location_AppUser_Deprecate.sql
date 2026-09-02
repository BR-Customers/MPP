-- =============================================
-- Procedure:   Location.AppUser_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Soft-deletes an AppUser by setting DeprecatedAt. Validates that the
--   target exists, is not already deprecated, is not the bootstrap account
--   (Id = 1), and is not the calling user (cannot deprecate self).
--   Future phases may add downstream dependency checks.
--
-- Parameters:
--   @Id BIGINT        - PK of the AppUser to deprecate. Required.
--   @AppUserId BIGINT - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Location.AppUser
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation/business-rule failures: Status=0, Message set, Audit_LogFailure.
--   - CATCH handler: rollback, Status=0, Audit_LogFailure, then RAISERROR.
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.4: dropped ClockNumber from JSON snapshots
--   2026-04-23 - 2.2 - Initials realignment: Initials added to JSON snapshots
--   2026-09-02 - 1.1 - Pin captured in the audit old/new snapshots so the
--                      retired PIN is recorded (it is never reissued).
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    -- Capture input for failure-log snapshots
    DECLARE @ProcName NVARCHAR(200) = N'Location.AppUser_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must exist
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @Id)
        BEGIN
            SET @Message = N'AppUser not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must not already be deprecated
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @Id AND DeprecatedAt IS NOT NULL)
        BEGIN
            SET @Message = N'AppUser is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================

        -- Cannot deprecate the bootstrap account
        IF @Id = 1
        BEGIN
            SET @Message = N'Cannot deprecate the bootstrap account (Id = 1).';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Cannot deprecate yourself
        IF @Id = @AppUserId
        BEGIN
            SET @Message = N'Cannot deprecate your own account.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- FUTURE: Check for active dependents. In Phase 1 no downstream tables
        -- reference AppUser except audit logs, which should not block deprecation.
        -- Future phases may add checks here for tables like Lots.LotEvent,
        -- Quality.InspectionResult, etc. that have an AppUserId FK.

        -- ====================
        -- Capture old values for audit
        -- ====================
        DECLARE @OldValue NVARCHAR(MAX);
        SELECT @OldValue =
            (SELECT Initials,
                    DisplayName,
                    Pin,
                    AdAccount,
                    IgnitionRole,
                    DeprecatedAt
             FROM Location.AppUser
             WHERE Id = @Id
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Location.AppUser
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        -- Capture new state for audit
        DECLARE @NewValue NVARCHAR(MAX);
        SELECT @NewValue =
            (SELECT Initials,
                    DisplayName,
                    Pin,
                    AdAccount,
                    IgnitionRole,
                    DeprecatedAt
             FROM Location.AppUser
             WHERE Id = @Id
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- Success audit INSIDE the transaction
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'AppUser',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = N'AppUser deprecated.',
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AppUser deprecated successfully.';
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

        -- Failure log OUTSIDE the rolled-back transaction
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
