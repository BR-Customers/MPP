-- =============================================
-- Procedure:   Location.AppUser_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     4.0
--
-- Description:
--   Updates mutable fields on an existing AppUser: Initials, DisplayName,
--   AdAccount, and IgnitionRole. Does NOT update DeprecatedAt (separate
--   proc: AppUser_Deprecate).
--
--   Initials are mutable to support typos and formatting fixes (e.g.,
--   upgrading 'JP' → 'JGP' when another JP joins the plant). Uniqueness
--   is re-validated on every update, excluding the row being updated.
--
--   AdAccount is mutable to support operators who later receive an AD
--   account when promoted to an interactive role. Pass NULL to clear.
--
--   Pin is mutable so an admin can re-issue a number when MPP recycles or
--   corrects one. Uniqueness is re-validated on every update, excluding the
--   row being updated -- the same treatment Initials and AdAccount get.
--
--   IgnitionRole requires AdAccount to be set — enforced here plus by
--   the CK_AppUser_IgnitionRole_Requires_AdAccount constraint.
--
-- Parameters:
--   @Id BIGINT                        - PK. Required.
--   @Initials NVARCHAR(10)            - Required. Unique (excluding self).
--   @DisplayName NVARCHAR(200)        - Required.
--   @Pin NVARCHAR(5)                  - Required. Unique (excluding self).
--                                       Leading zeros significant -- string, not a number.
--   @AdAccount NVARCHAR(100) NULL     - Optional. Unique among non-NULL (excluding self).
--   @IgnitionRole NVARCHAR(100) NULL  - Optional. Requires @AdAccount to be set.
--   @AppUserId BIGINT                 - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Location.AppUser
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.4: dropped @ClockNumber (legacy auth)
--   2026-04-23 - 3.0 - Initials realignment: @Initials added, @AdAccount
--                      now mutable, IgnitionRole/AdAccount pairing enforced
--   2026-09-02 - 4.0 - @Pin added (required): format + uniqueness validated
--                      here ahead of the DB constraints; Pin carried into
--                      both audit JSON snapshots.
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_Update
    @Id           BIGINT,
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

    DECLARE @ProcName NVARCHAR(200) = N'Location.AppUser_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id           AS Id,
                @Initials     AS Initials,
                @DisplayName  AS DisplayName,
                @Pin          AS Pin,
                @AdAccount    AS AdAccount,
                @IgnitionRole AS IgnitionRole
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @Initials IS NULL OR @DisplayName IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF LEN(@Initials) = 0
        BEGIN
            SET @Message = N'Initials cannot be empty.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must exist and not be deprecated
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'AppUser not found or is deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Initials unique (excluding self)
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = @Initials AND Id <> @Id)
        BEGIN
            SET @Message = N'Another AppUser already has these Initials.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- AdAccount uniqueness (only when supplied, excluding self)
        IF @AdAccount IS NOT NULL AND EXISTS
            (SELECT 1 FROM Location.AppUser WHERE AdAccount = @AdAccount AND Id <> @Id)
        BEGIN
            SET @Message = N'Another AppUser already has this AdAccount.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
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
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- PIN uniqueness across ALL rows (active + deprecated), excluding self
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = @Pin AND Id <> @Id)
        BEGIN
            SET @Message = N'Another AppUser already has this PIN.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- IgnitionRole requires AdAccount
        IF @IgnitionRole IS NOT NULL AND @AdAccount IS NULL
        BEGIN
            SET @Message = N'IgnitionRole cannot be set without an AdAccount.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Capture old values for audit diff
        -- ====================
        DECLARE @OldValue NVARCHAR(MAX);
        SELECT @OldValue =
            (SELECT Initials,
                    DisplayName,
                    Pin,
                    AdAccount,
                    IgnitionRole
             FROM Location.AppUser
             WHERE Id = @Id
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @NewValue NVARCHAR(MAX) =
            (SELECT @Initials     AS Initials,
                    @DisplayName  AS DisplayName,
                    @Pin          AS Pin,
                    @AdAccount    AS AdAccount,
                    @IgnitionRole AS IgnitionRole
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Location.AppUser
        SET Initials     = @Initials,
            DisplayName  = @DisplayName,
            Pin          = @Pin,
            AdAccount    = @AdAccount,
            IgnitionRole = @IgnitionRole
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'AppUser',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'AppUser updated.',
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AppUser updated successfully.';
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
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
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
