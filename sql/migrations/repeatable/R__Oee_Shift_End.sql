-- ============================================================
-- Repeatable:  R__Oee_Shift_End.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Closes the currently-open runtime Oee.Shift (sets ActualEnd).
--              Rejects (status row, NOT an exception) when there is NO open
--              shift. Phase 1: NO auto-carryover of open events on end (open
--              production/downtime events are NOT touched). Audits 'ShiftEnded'
--              (entity 'Shift') on success.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params; every exit path ends SELECT @Status, @Message.
--              RAISERROR (not THROW) in the nested CATCH with failure logging.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.Shift_End
    @ActualEnd          DATETIME2(3)  = NULL,   -- defaults to now (UTC)
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.Shift_End';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ActualEnd AS ActualEnd, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @ShiftId      BIGINT;
    DECLARE @ScheduleName NVARCHAR(100);
    DECLARE @Start        DATETIME2(3);

    BEGIN TRY
        IF @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (AppUserId).';
            -- cannot Audit_LogFailure here: no @AppUserId to attribute the failure to
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT TOP 1 @ShiftId = s.Id, @Start = s.ActualStart, @ScheduleName = ss.Name
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualEnd IS NULL
        ORDER BY s.ActualStart DESC, s.Id DESC;

        IF @ShiftId IS NULL
        BEGIN
            SET @Message = N'No open shift to end.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift',
                @EntityId = NULL, @LogEventTypeCode = N'ShiftEnded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @End DATETIME2(3) = ISNULL(@ActualEnd, SYSUTCDATETIME());

        -- ===== Mutation (atomic) =====
        -- Phase 1: NO auto-carryover. We close ONLY the Shift row; any open
        -- production / downtime events are intentionally left untouched.
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @ScheduleName + N' ' + Audit.ufn_MidDot() + N' Shift ' + Audit.ufn_MidDot()
            + N' Ended ' + CONVERT(NVARCHAR(23), @End, 121);
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT @ShiftId AS ShiftId, @ScheduleName AS ScheduleName, @Start AS ActualStart
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @ShiftId AS ShiftId, @ScheduleName AS ScheduleName,
                   @Start AS ActualStart, @End AS ActualEnd
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Oee.Shift
        SET ActualEnd = @End,
            Remarks   = ISNULL(@Remarks, Remarks)
        WHERE Id = @ShiftId;

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Shift',
            @EntityId           = @ShiftId,
            @LogEventTypeCode   = N'ShiftEnded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shift ended.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift',
                @EntityId = @ShiftId, @LogEventTypeCode = N'ShiftEnded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
