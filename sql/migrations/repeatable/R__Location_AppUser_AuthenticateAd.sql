-- =============================================
-- Procedure:   Location.AppUser_AuthenticateAd
-- Author:      Blue Ridge Automation
-- Created:     2026-06-09
-- Version:     1.0
--
-- Description:
--   Resolves a per-action AD elevation (FDS-04-006) for an AD account whose
--   password has ALREADY been validated by Ignition's built-in AD binding in
--   the Perspective elevation modal. This proc does NOT validate a password
--   and does NOT authorize by action: roles are defined in Ignition and the
--   per-action authorization decision is made in the UI layer using the
--   IgnitionRole returned here. The proc:
--     1. authenticates that the supplied @AdAccount maps to an ACTIVE AppUser,
--     2. returns that user's Id + IgnitionRole for the UI to make its
--        authorization decision, and
--     3. records the elevation outcome to the audit (granted / denied).
--
--   @ActionCode is recorded in the audit Description (the action the elevation
--   is being requested for) but is NEVER used to gate the result — there is no
--   action->role mapping in SQL.
--
--   Elevation events use entity code 'AppUser', which routes through
--   Audit_LogOperation/Audit_LogFailure to the general OperationLog/FailureLog
--   (only entity 'Lot' is split to Lots.LotEventLog).
--
-- Parameters:
--   @AdAccount          NVARCHAR(100)      - AD identity to authenticate. Required.
--   @ActionCode         NVARCHAR(50) NULL  - Action being elevated for. Recorded only.
--   @TerminalLocationId BIGINT       NULL  - B1 terminal context for the audit row.
--   @AppUserId          BIGINT       NULL  - Operator presence id, for audit attribution.
--
-- Result set (single row, NO OUTPUT params):
--   Status (BIT), Message (NVARCHAR), AppUserId (BIGINT), IgnitionRole (NVARCHAR).
--   Status=1 + resolved AppUserId/IgnitionRole on success; Status=0 + NULL
--   AppUserId/IgnitionRole on any rejection.
--
-- Dependencies:
--   Tables: Location.AppUser
--   Procs:  Audit.Audit_LogOperation, Audit.Audit_LogFailure
--   Seeds:  Audit.LogEventType 'ElevationGranted'/'ElevationDenied' (0020 §D)
--
-- Change Log:
--   2026-06-09 - 1.0 - Initial version (Arc 2 Phase 1 Task D).
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_AuthenticateAd
    @AdAccount          NVARCHAR(100),
    @ActionCode         NVARCHAR(50)  = NULL,
    @TerminalLocationId BIGINT        = NULL,
    @AppUserId          BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status        BIT            = 0;
    DECLARE @Message       NVARCHAR(500)  = N'Unknown error';
    DECLARE @ResolvedId    BIGINT         = NULL;
    DECLARE @IgnitionRole  NVARCHAR(100)  = NULL;
    -- Audit.FailureLog.AppUserId is NOT NULL; a denied elevation may have no
    -- resolved/presence user, so attribute the failure row to the bootstrap
    -- user (Id 1) when the caller supplies none. (Success audits to @ResolvedId.)
    DECLARE @AppUserIdEff  BIGINT         = ISNULL(@AppUserId, 1);

    DECLARE @ProcName NVARCHAR(200) = N'Location.AppUser_AuthenticateAd';
    DECLARE @ActionLabel NVARCHAR(50) = ISNULL(@ActionCode, N'(unspecified)');
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @AdAccount          AS AdAccount,
                @ActionCode         AS ActionCode,
                @TerminalLocationId AS TerminalLocationId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @AdAccount IS NULL OR LEN(@AdAccount) = 0
        BEGIN
            SET @Message = N'AD account is required for elevation.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserIdEff,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'ElevationDenied',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ResolvedId AS AppUserId, @IgnitionRole AS IgnitionRole;
            RETURN;
        END

        -- ====================
        -- Authenticate identity: must map to an ACTIVE AppUser
        -- ====================
        SELECT @ResolvedId   = Id,
               @IgnitionRole = IgnitionRole
        FROM Location.AppUser
        WHERE AdAccount = @AdAccount
          AND DeprecatedAt IS NULL;

        IF @ResolvedId IS NULL
        BEGIN
            SET @Message = N'AD account not recognised or is deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserIdEff,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'ElevationDenied',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ResolvedId AS AppUserId, @IgnitionRole AS IgnitionRole;
            RETURN;
        END

        -- ====================
        -- Authenticated: record the grant (NO authorization in SQL — the UI
        -- decides based on the returned IgnitionRole). @ActionCode is recorded.
        -- ====================
        DECLARE @Desc NVARCHAR(1000) =
            N'AD elevation granted for action ' + @ActionLabel + N'.';

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @ResolvedId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'AppUser',
            @EntityId           = @ResolvedId,
            @LogEventTypeCode   = N'ElevationGranted',
            @LogSeverityCode    = N'Info',
            @Description        = @Desc;

        SET @Status  = 1;
        SET @Message = N'AD elevation authenticated.';
        SELECT @Status AS Status, @Message AS Message, @ResolvedId AS AppUserId, @IgnitionRole AS IgnitionRole;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status       = 0;
        SET @Message      = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @ResolvedId   = NULL;
        SET @IgnitionRole = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserIdEff,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'ElevationDenied',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @ResolvedId AS AppUserId, @IgnitionRole AS IgnitionRole;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
