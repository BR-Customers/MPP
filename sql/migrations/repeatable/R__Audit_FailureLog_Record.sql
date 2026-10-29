-- =============================================
-- Procedure:   Audit.FailureLog_Record
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
--
-- Description:
--   Writes one Audit.FailureLog row on behalf of a caller OUTSIDE SQL -- an
--   Ignition script (BlueRidge.Audit.FailureLog.record) reporting a failure
--   that no mutation proc saw, e.g. an AIM post that AIM refused. First caller:
--   the AIM integration (MPP request 2026-09-16).
--
--   WHY A SEPARATE PROC. Audit.Audit_LogFailure is the silent writer mutation
--   procs call inside their own transactions; it must keep emitting NO result
--   set (FDS-11-011), so it cannot back a Query-typed named query. This is its
--   status-row twin. The INSERT is INLINED (it mirrors Audit_LogFailure v1.1 --
--   keep the column lists in step) rather than EXEC'd, per the INSERT-EXEC rule.
--
--   Stricter than Audit_LogFailure on purpose:
--     - an unknown @LogEntityTypeCode / @LogEventTypeCode is REFUSED, not
--       silently filed under Id 1;
--     - @FailureReason is truncated to 500 chars (Audit.ufn_TruncateActivity)
--       rather than failing on overflow -- an AIM error body can be long, and a
--       failure that cannot be logged is worse than a shortened reason.
--   Lenient on the context ids: a @LocationId / @LotId that names no row is
--   stored as NULL instead of refusing the write, for the same reason.
--
--   It does NOT log its own refusals to FailureLog (no recursion); the caller
--   sees Status = 0 and writes the gateway log.
--
-- Parameters:
--   @AppUserId           BIGINT         - Required. Who the attempt is attributed to
--                                         (the operator, or AppUser 1 for a timer).
--   @LogEntityTypeCode   NVARCHAR(50)   - Required. Audit.LogEntityType.Code.
--   @EntityId            BIGINT NULL    - The entity's Id, when there is one.
--   @LogEventTypeCode    NVARCHAR(50)   - Required. Audit.LogEventType.Code.
--   @FailureReason       NVARCHAR(MAX)  - Required. Truncated to 500.
--   @ProcedureName       NVARCHAR(200)  - Required. The script function / proc that failed.
--   @AttemptedParameters NVARCHAR(MAX)  - Optional JSON metadata.
--   @LocationId          BIGINT NULL    - Where it happened.
--   @LotId               BIGINT NULL    - The LOT it concerned.
--
-- Result set:
--   One row: Status (BIT), Message (NVARCHAR(500)), NewId (BIGINT, the FailureLog Id).
--
-- Change Log:
--   2026-10-29 - 1.0 - Initial version (migration 0116).
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_Record
    @AppUserId           BIGINT,
    @LogEntityTypeCode   NVARCHAR(50),
    @EntityId            BIGINT          = NULL,
    @LogEventTypeCode    NVARCHAR(50),
    @FailureReason       NVARCHAR(MAX),
    @ProcedureName       NVARCHAR(200),
    @AttemptedParameters NVARCHAR(MAX)   = NULL,
    @LocationId          BIGINT          = NULL,
    @LotId               BIGINT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @LogEntityTypeId BIGINT;
    DECLARE @LogEventTypeId  BIGINT;

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @AppUserId IS NULL OR @LogEntityTypeCode IS NULL OR @LogEventTypeCode IS NULL
           OR NULLIF(LTRIM(RTRIM(@FailureReason)), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM(@ProcedureName)), N'') IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (AppUserId, entity type, event type, reason and procedure name are required).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'Unknown AppUserId ' + CAST(@AppUserId AS NVARCHAR(20)) + N'.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @LogEntityTypeId = Id FROM Audit.LogEntityType WHERE Code = @LogEntityTypeCode;
        IF @LogEntityTypeId IS NULL
        BEGIN
            SET @Message = N'Unknown log entity type code ''' + @LogEntityTypeCode + N'''.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @LogEventTypeId = Id FROM Audit.LogEventType WHERE Code = @LogEventTypeCode;
        IF @LogEventTypeId IS NULL
        BEGIN
            SET @Message = N'Unknown log event type code ''' + @LogEventTypeCode + N'''.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Context ids that name no row are dropped, not refused (see header).
        IF @LocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @LocationId)
            SET @LocationId = NULL;
        IF @LotId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @LotId)
            SET @LotId = NULL;

        -- ====================
        -- Insert (mirrors Audit.Audit_LogFailure v1.1)
        -- ====================
        INSERT INTO Audit.FailureLog (
            AttemptedAt,
            AppUserId,
            LogEntityTypeId,
            EntityId,
            LogEventTypeId,
            FailureReason,
            ProcedureName,
            AttemptedParameters,
            LocationId,
            LotId
        )
        VALUES (
            SYSUTCDATETIME(),
            @AppUserId,
            @LogEntityTypeId,
            @EntityId,
            @LogEventTypeId,
            Audit.ufn_TruncateActivity(@FailureReason),
            @ProcedureName,
            @AttemptedParameters,
            @LocationId,
            @LotId
        );

        SET @NewId   = CAST(SCOPE_IDENTITY() AS BIGINT);
        SET @Status  = 1;
        SET @Message = N'Failure recorded.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = LEFT(N'Could not record failure: ' + @ErrMsg, 500);
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
