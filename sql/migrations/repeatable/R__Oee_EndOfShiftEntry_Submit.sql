-- ============================================================
-- Repeatable:  R__Oee_EndOfShiftEntry_Submit.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: End-of-shift time entry (FDS-09-013). The operator selects which
--              lunch/breaks they took; the system writes one CLOSED
--              Oee.DowntimeEvent per selected break, with the duration resolved
--              from the break reason code's StandardDurationMinutes (NOT
--              operator-entered). StartedAt is the shift's ActualStart (nominal --
--              only the duration is meaningful for availability). Zero selected =
--              valid (writes no rows). One submission per operator per shift
--              (re-submission rejected). Audits 'EndOfShiftSubmitted'.
--              @BreaksSelectedJson is a JSON array of DowntimeReasonCode Ids, e.g.
--              '[3,4]'. Returns SELECT @Status, @Message, @EventCountInserted.
--              Recorded divergence from FDS-09-013: breaks are fixed reason codes
--              with uniform durations, not per-schedule config (spec section 3.2).
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.EndOfShiftEntry_Submit
    @ShiftId             BIGINT,
    @CellLocationId      BIGINT,
    @BreaksSelectedJson  NVARCHAR(MAX),
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status     BIT           = 0;
    DECLARE @Message    NVARCHAR(500) = N'Unknown error';
    DECLARE @EventCount INT           = 0;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.EndOfShiftEntry_Submit';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ShiftId AS ShiftId, @CellLocationId AS CellLocationId,
               @BreaksSelectedJson AS BreaksSelectedJson, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @ActualStart DATETIME2(3), @ActualEnd DATETIME2(3);
    DECLARE @OperatorSrcId BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
    DECLARE @Sel TABLE (Id BIGINT PRIMARY KEY);

    BEGIN TRY
        IF @ShiftId IS NULL OR @CellLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShiftId, CellLocationId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
            RETURN;
        END

        SELECT @ActualStart = s.ActualStart, @ActualEnd = s.ActualEnd
        FROM Oee.Shift s WHERE s.Id = @ShiftId;

        IF @ActualStart IS NULL
        BEGIN
            SET @Message = N'Shift not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'EndOfShiftSubmitted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
            RETURN;
        END

        IF @ActualEnd IS NOT NULL
        BEGIN
            SET @Message = N'Shift is already closed.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'EndOfShiftSubmitted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @CellLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Cell location not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'EndOfShiftSubmitted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
            RETURN;
        END

        -- ---- one submission per operator per shift ----
        IF EXISTS (SELECT 1 FROM Oee.DowntimeEvent de
                   INNER JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
                   INNER JOIN Oee.DowntimeReasonType rt ON rt.Id = rc.DowntimeReasonTypeId
                   WHERE de.ShiftId = @ShiftId AND de.AppUserId = @AppUserId AND rt.Code = N'Break')
        BEGIN
            SET @Message = N'End-of-shift entry already submitted for this shift.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'EndOfShiftSubmitted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
            RETURN;
        END

        -- ---- parse the selected break ids (scalar JSON array) ----
        IF @BreaksSelectedJson IS NOT NULL AND LTRIM(RTRIM(@BreaksSelectedJson)) NOT IN (N'', N'[]')
            INSERT INTO @Sel (Id) SELECT DISTINCT CAST(value AS BIGINT) FROM OPENJSON(@BreaksSelectedJson);

        -- every selected id must be an active break code with a standard duration
        IF EXISTS (SELECT 1 FROM @Sel s WHERE NOT EXISTS (
                    SELECT 1 FROM Oee.DowntimeReasonCode rc
                    WHERE rc.Id = s.Id AND rc.DeprecatedAt IS NULL AND rc.StandardDurationMinutes IS NOT NULL))
        BEGIN
            SET @Message = N'One or more selected breaks are invalid or have no standard duration.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'EndOfShiftSubmitted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
            RETURN;
        END

        -- ---- mutation ----
        BEGIN TRANSACTION;

        INSERT INTO Oee.DowntimeEvent
            (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, AppUserId)
        SELECT @CellLocationId, rc.Id, @ShiftId, @ActualStart,
               DATEADD(MINUTE, rc.StandardDurationMinutes, @ActualStart), @OperatorSrcId, @AppUserId
        FROM @Sel s INNER JOIN Oee.DowntimeReasonCode rc ON rc.Id = s.Id;

        SET @EventCount = @@ROWCOUNT;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Shift ' + CAST(@ShiftId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' End-of-Shift ' + Audit.ufn_MidDot()
            + N' Submitted (' + CAST(@EventCount AS NVARCHAR(10)) + N' break event(s))');
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT @ShiftId AS ShiftId, @EventCount AS EventCountInserted FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @CellLocationId,
            @LogEntityTypeCode  = N'DowntimeEvent',
            @EntityId           = @ShiftId,
            @LogEventTypeCode   = N'EndOfShiftSubmitted',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'End-of-shift entry submitted.';
        SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status     = 0;
        SET @Message    = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @EventCount = 0;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'EndOfShiftSubmitted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @EventCount AS EventCountInserted;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
