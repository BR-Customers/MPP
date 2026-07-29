-- ============================================================
-- Repeatable:  R__Audit_OperatorChange_Log.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Logs a terminal operator handoff ("any terminal user id change needs to be
--              logged"). Fired from InitialsEntry.loginAs on every sign-in path. Resolves
--              operator names + terminal code, builds the SUBJECT * CATEGORY * ACTION
--              description + resolved-name Old/New JSON, and writes ONE Audit.OperationLog
--              row via Audit.Audit_LogOperation (entity AppUser, event OperatorChanged).
--
--              Defaults (Jacques 2026-07-23): attribution = the NEW operator; fires on first
--              bind (old NULL -> "Signed in"); SUPPRESSES a same-operator re-scan (no row).
--
--              FDS-11-011: no OUTPUT params; single terminal SELECT @Status,@Message. All
--              rejects run BEFORE BEGIN TRANSACTION. RAISERROR (not THROW) in CATCH.
--              Audit_LogOperation emits no result set -> this proc is INSERT-EXEC safe.
-- ============================================================

CREATE OR ALTER PROCEDURE Audit.OperatorChange_Log
    @OldAppUserId       BIGINT = NULL,   -- NULL on first bind / unresolvable -> null OldValue
    @NewAppUserId       BIGINT,          -- required
    @TerminalLocationId BIGINT = NULL,   -- NULL on the fallback/unregistered terminal
    @AppUserId          BIGINT = NULL     -- attribution; defaults to @NewAppUserId
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Audit.OperatorChange_Log';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @OldAppUserId AS OldAppUserId, @NewAppUserId AS NewAppUserId,
        @TerminalLocationId AS TerminalLocationId, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @NewInit NVARCHAR(10), @NewName NVARCHAR(100), @OldInit NVARCHAR(10), @OldName NVARCHAR(100);
    DECLARE @TermCode NVARCHAR(50), @TermLabel NVARCHAR(50), @Action NVARCHAR(200);
    DECLARE @Description NVARCHAR(500), @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ---- pre-transaction guards ----
        IF @NewAppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (NewAppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @NewInit = Initials, @NewName = DisplayName FROM Location.AppUser WHERE Id = @NewAppUserId;
        IF @NewInit IS NULL
        BEGIN
            SET @Message = N'New operator (AppUser ' + CAST(@NewAppUserId AS NVARCHAR(20)) + N') not found.';
            EXEC Audit.Audit_LogFailure @AppUserId = @NewAppUserId, @LogEntityTypeCode = N'AppUser',
                @EntityId = @NewAppUserId, @LogEventTypeCode = N'OperatorChanged', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        -- no-op: same operator re-scan -> suppress (no audit noise)
        IF @OldAppUserId IS NOT NULL AND @OldAppUserId = @NewAppUserId
        BEGIN
            SET @Status = 1; SET @Message = N'No operator change.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SET @AppUserId = ISNULL(@AppUserId, @NewAppUserId);

        -- resolve old (if supplied + resolvable; unresolvable degrades to null OldValue, never rejects)
        IF @OldAppUserId IS NOT NULL
            SELECT @OldInit = Initials, @OldName = DisplayName FROM Location.AppUser WHERE Id = @OldAppUserId;

        SET @TermCode  = (SELECT Code FROM Location.Location WHERE Id = @TerminalLocationId);
        SET @TermLabel = ISNULL(@TermCode, N'Terminal');

        SET @Action = CASE WHEN @OldInit IS NOT NULL
            THEN N'Changed ' + @OldInit + N' -> ' + @NewInit
            ELSE N'Signed in ' + @NewInit END;
        SET @Description = Audit.ufn_TruncateActivity(
            @TermLabel + N' ' + Audit.ufn_MidDot() + N' Operator ' + Audit.ufn_MidDot() + N' ' + @Action);

        SET @NewValue = (SELECT JSON_QUERY((SELECT au.Id, au.Initials AS Code, au.DisplayName AS Name
            FROM Location.AppUser au WHERE au.Id = @NewAppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS AppUser
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @OldValue = CASE WHEN @OldInit IS NULL THEN NULL ELSE
            (SELECT JSON_QUERY((SELECT au.Id, au.Initials AS Code, au.DisplayName AS Name
                FROM Location.AppUser au WHERE au.Id = @OldAppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS AppUser
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;

        -- ---- write (single Audit_LogOperation row; wrapped for CATCH symmetry) ----
        BEGIN TRANSACTION;
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'AppUser', @EntityId = @NewAppUserId, @LogEventTypeCode = N'OperatorChanged',
            @LogSeverityCode = N'Info', @Description = @Description, @OldValue = @OldValue, @NewValue = @NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Operator change logged.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @NewAppUserId, @LogEntityTypeCode = N'AppUser',
                @EntityId = @NewAppUserId, @LogEventTypeCode = N'OperatorChanged', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
