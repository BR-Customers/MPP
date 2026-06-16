-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_Start.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Opens a downtime event at a machine/Cell (Arc 2 Phase 8,
--              FDS-09-005/010). B3: rejects if an open event already exists for
--              @LocationId (clean pre-check before the filtered-unique
--              UX_DowntimeEvent_OneOpenPerLocation). Resolves the active Shift
--              (NULL-safe). Reason MAY be NULL (late-binding, B7); Source is
--              Operator or PLC. Audits 'DowntimeStarted' to Audit.OperationLog.
--              Returns SELECT @Status, @Message, @NewId. No OUTPUT params
--              (FDS-11-011). RAISERROR (not THROW) in the nested CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_Start
    @LocationId           BIGINT,
    @DowntimeSourceCodeId BIGINT,
    @DowntimeReasonCodeId  BIGINT = NULL,
    @ShotCount            INT    = NULL,
    @AppUserId            BIGINT = NULL,
    @TerminalLocationId   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_Start';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LocationId AS LocationId, @DowntimeSourceCodeId AS DowntimeSourceCodeId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode NVARCHAR(50);
    DECLARE @ShiftId BIGINT;

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @LocationId IS NULL OR @DowntimeSourceCodeId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LocationId, DowntimeSourceCodeId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = NULL,
                    @LogEventTypeCode = N'DowntimeStarted', @FailureReason = @Message,
                    @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId AND DeprecatedAt IS NULL;
        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = NULL,
                @LogEventTypeCode = N'DowntimeStarted', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeSourceCode WHERE Id = @DowntimeSourceCodeId)
        BEGIN
            SET @Message = N'Downtime source code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = NULL,
                @LogEventTypeCode = N'DowntimeStarted', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- B3 open-event invariant: clean pre-check before the filtered-unique ----
        IF EXISTS (SELECT 1 FROM Oee.DowntimeEvent WHERE LocationId = @LocationId AND EndedAt IS NULL)
        BEGIN
            SET @Message = N'An open downtime event already exists at this location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = NULL,
                @LogEventTypeCode = N'DowntimeStarted', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Active shift (may be NULL -- downtime still records; FDS-09-010).
        SELECT TOP 1 @ShiftId = Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC;

        -- ---- Audit narrative + resolved-FK NewValue (pre-mutation) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Started';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @LocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Oee.DowntimeSourceCode sc WHERE sc.Id = @DowntimeSourceCodeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Source,
                   @ShotCount AS ShotCount
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Oee.DowntimeEvent
            (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, DowntimeSourceCodeId, AppUserId, ShotCount)
        VALUES
            (@LocationId, @DowntimeReasonCodeId, @ShiftId, SYSUTCDATETIME(), @DowntimeSourceCodeId, @AppUserId, @ShotCount);

        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LocationId,
            @LogEntityTypeCode  = N'DowntimeEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'DowntimeStarted',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Downtime started.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = NULL,
                @LogEventTypeCode = N'DowntimeStarted', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
