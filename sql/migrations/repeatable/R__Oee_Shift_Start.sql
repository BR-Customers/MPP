-- ============================================================
-- Repeatable:  R__Oee_Shift_Start.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Opens a new runtime Oee.Shift instance for a given
--              ShiftSchedule. Enforces the B3 single-open invariant: rejects
--              (status row, NOT an exception) when ANY open Shift already
--              exists (ActualEnd IS NULL). Audits 'ShiftStarted' (entity
--              'Shift') on success.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params; every exit path ends SELECT @Status, @Message, @NewId.
--              RAISERROR (not THROW) in the nested CATCH with failure logging.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.Shift_Start
    @ShiftScheduleId    BIGINT,
    @ActualStart        DATETIME2(3)  = NULL,   -- defaults to now (UTC)
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.Shift_Start';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ShiftScheduleId AS ShiftScheduleId, @ActualStart AS ActualStart,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @ScheduleName NVARCHAR(100);

    BEGIN TRY
        IF @ShiftScheduleId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShiftScheduleId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift',
                    @EntityId = NULL, @LogEventTypeCode = N'ShiftStarted',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @ScheduleName = Name
        FROM Oee.ShiftSchedule
        WHERE Id = @ShiftScheduleId AND DeprecatedAt IS NULL;

        IF @ScheduleName IS NULL
        BEGIN
            SET @Message = N'Shift schedule not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift',
                @EntityId = @ShiftScheduleId, @LogEventTypeCode = N'ShiftStarted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- B3 single-open invariant: reject if any shift is currently open.
        IF EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
        BEGIN
            SET @Message = N'An open shift already exists. End it before starting a new one.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift',
                @EntityId = @ShiftScheduleId, @LogEventTypeCode = N'ShiftStarted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @Start DATETIME2(3) = ISNULL(@ActualStart, SYSUTCDATETIME());

        -- ===== Mutation (atomic) =====
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @ScheduleName + N' ' + Audit.ufn_MidDot() + N' Shift ' + Audit.ufn_MidDot()
            + N' Started ' + CONVERT(NVARCHAR(23), @Start, 121);
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @ShiftScheduleId AS ShiftScheduleId, @ScheduleName AS ScheduleName,
                   @Start AS ActualStart
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
        VALUES (@ShiftScheduleId, @Start, NULL, @Remarks);

        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Shift',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'ShiftStarted',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shift started.';
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

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift',
                @EntityId = @ShiftScheduleId, @LogEventTypeCode = N'ShiftStarted',
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
