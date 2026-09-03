-- =============================================
-- Procedure:   Location.AppUser_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     4.0
--
-- Description:
--   Creates a new AppUser row. Initials are the primary accountability
--   stamp — required, unique. AdAccount is optional (operators have no
--   AD login); IgnitionRole requires AdAccount to be set (enforced by
--   both a proc-level check and the CK_AppUser_IgnitionRole_Requires_AdAccount
--   constraint).
--
-- Parameters:
--   @Initials NVARCHAR(10)            - Operator/user initials. Required. Unique.
--   @DisplayName NVARCHAR(200)        - Display name. Required.
--   @Pin NVARCHAR(5)                  - 5-digit sign-in PIN. Required for EVERY user.
--                                       Unique across all rows including deprecated.
--                                       Leading zeros significant -- string, not a number.
--   @AdAccount NVARCHAR(100) NULL     - AD identity. Optional. Unique among non-NULL values.
--   @IgnitionRole NVARCHAR(100) NULL  - Optional role. Requires @AdAccount to be set.
--   @AppUserId BIGINT                 - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
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
--   2026-04-14 - 2.0 - Changed to SELECT result for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.4: dropped @ClockNumber + @PinHash (legacy auth)
--   2026-04-23 - 3.0 - Initials realignment: @Initials NOT NULL required,
--                      @AdAccount now optional, IgnitionRole/AdAccount pairing enforced
--   2026-09-02 - 4.0 - @Pin added (required): users sign in by PIN. Uniqueness
--                      and 5-digit format validated here ahead of the DB
--                      constraints so the UI gets a readable message.
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_Create
    @Initials     NVARCHAR(10),
    @DisplayName  NVARCHAR(200),
    @Pin          NVARCHAR(5),
    @AdAccount    NVARCHAR(100)  = NULL,
    @IgnitionRole NVARCHAR(100)  = NULL,
    @AppUserId    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Location.AppUser_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Initials     AS Initials,
                @DisplayName  AS DisplayName,
                @Pin          AS Pin,
                @AdAccount    AS AdAccount,
                @IgnitionRole AS IgnitionRole
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Initials IS NULL OR @DisplayName IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF LEN(@Initials) = 0
        BEGIN
            SET @Message = N'Initials cannot be empty.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================
        -- Initials unique across ALL rows (active + deprecated) because the
        -- constraint is a plain UNIQUE, not a filtered index.
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = @Initials)
        BEGIN
            SET @Message = N'An AppUser with these Initials already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- AdAccount uniqueness — only enforced when supplied (filtered UNIQUE)
        IF @AdAccount IS NOT NULL AND EXISTS
            (SELECT 1 FROM Location.AppUser WHERE AdAccount = @AdAccount)
        BEGIN
            SET @Message = N'An AppUser with this AdAccount already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- PIN format: exactly 5 numeric digits (mirrors CK_AppUser_Pin_Format).
        -- A leading zero is legal and significant -- 04218 is a full-time
        -- employee's code -- so this must never be a numeric comparison.
        IF @Pin IS NULL OR LEN(@Pin) <> 5 OR @Pin LIKE '%[^0-9]%'
        BEGIN
            SET @Message = N'PIN must be exactly 5 digits.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- PIN uniqueness across ALL rows (active + deprecated): a retired
        -- person's PIN stays reserved so historical attribution can never
        -- collide with a newly issued one.
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = @Pin)
        BEGIN
            SET @Message = N'An AppUser with this PIN already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- IgnitionRole requires AdAccount (enforced at DB via CHECK constraint,
        -- but caught here for a friendly message before the INSERT fires)
        IF @IgnitionRole IS NOT NULL AND @AdAccount IS NULL
        BEGIN
            SET @Message = N'IgnitionRole cannot be set without an AdAccount.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Location.AppUser
            (Initials, DisplayName, Pin, AdAccount, IgnitionRole, CreatedAt)
        VALUES
            (@Initials, @DisplayName, @Pin, @AdAccount, @IgnitionRole, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'AppUser',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'AppUser created.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AppUser created successfully.';
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
                @LogEntityTypeCode   = N'AppUser',
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
