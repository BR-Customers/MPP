-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_RecordApproximate.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-04
-- Version:     1.0
-- Description: Records a duration-only ("approximate") past downtime event from the
--              Downtime Manager / editor. The end-of-shift case: the operator knows
--              "down ~45 min this shift" but not the exact window. Stores a NOMINAL
--              shift-anchored window (StartedAt = shift start, EndedAt = start +
--              duration) so the one-open filtered-unique index stays satisfied
--              (EndedAt set) and shift OEE bucketing works, with IsApproximate=1
--              flagging that the window is not precise -- only DurationMinutes +
--              ShiftId are authoritative. DurationMinutes is stored (operator input).
--              Source = 'Operator'. Audits 'DowntimeRecordedHistorical' (row's
--              IsApproximate flag distinguishes it). Returns SELECT @Status,
--              @Message, @NewId. All rejects before BEGIN TRANSACTION.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId      BIGINT,
    @DurationMinutes      INT,
    @ShiftId              BIGINT        = NULL,
    @DowntimeReasonCodeId BIGINT        = NULL,
    @Remarks              NVARCHAR(500) = NULL,
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_RecordApproximate';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ScopeLocationId AS ScopeLocationId, @DurationMinutes AS DurationMinutes, @ShiftId AS ShiftId,
               @DowntimeReasonCodeId AS DowntimeReasonCodeId, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode NVARCHAR(50), @SourceId BIGINT, @Shift BIGINT, @StartUtc DATETIME2(3), @EndUtc DATETIME2(3);

    BEGIN TRY
        IF @ScopeLocationId IS NULL OR @DurationMinutes IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ScopeLocationId, DurationMinutes, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
        IF @DurationMinutes <= 0
        BEGIN
            SET @Message = N'Duration must be greater than zero.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @ScopeLocationId AND DeprecatedAt IS NULL;
        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Location not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeRecordedHistorical', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
        IF @DowntimeReasonCodeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Id = @DowntimeReasonCodeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Reason code not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeRecordedHistorical', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Resolve shift: an explicit @ShiftId still WINS (the operator picked
        -- it). Only the FALLBACK changed -- shift-override attribution, spec
        -- sec 4.2: Oee.ufn_ShiftIdForInstant for THIS equipment at now, instead
        -- of "whichever shift is open plant-wide". A press extended past the
        -- plant boundary now falls back to its OWN shift.
        SET @Shift = @ShiftId;
        IF @Shift IS NULL
            SELECT @Shift = r.ShiftId
            FROM Oee.ufn_ShiftIdForInstant(@ScopeLocationId, SYSUTCDATETIME()) r;
        ELSE IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @Shift)
        BEGIN
            SET @Message = N'Shift not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Nominal anchor: shift start (fallback: now - duration when no shift is known).
        SELECT @StartUtc = ActualStart FROM Oee.Shift WHERE Id = @Shift;
        IF @StartUtc IS NULL
            SET @StartUtc = DATEADD(MINUTE, -@DurationMinutes, SYSUTCDATETIME());
        SET @EndUtc = DATEADD(MINUTE, @DurationMinutes, @StartUtc);

        SET @SourceId = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot()
            + N' Recorded (approximate ' + CAST(@DurationMinutes AS NVARCHAR(20)) + N' min)');
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @ScopeLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   JSON_QUERY((SELECT rc.Id, rc.Code, rc.Description AS Name FROM Oee.DowntimeReasonCode rc WHERE rc.Id = @DowntimeReasonCodeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode,
                   @DurationMinutes AS DurationMinutes,
                   CAST(1 AS BIT)   AS IsApproximate,
                   @Remarks         AS Remarks
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        INSERT INTO Oee.DowntimeEvent
            (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, AppUserId, Remarks, IsApproximate, DurationMinutes)
        VALUES
            (@ScopeLocationId, @DowntimeReasonCodeId, @Shift, @StartUtc, @EndUtc, @SourceId, @AppUserId, @Remarks, 1, @DurationMinutes);
        SET @NewId = SCOPE_IDENTITY();
        EXEC Audit.Audit_LogOperation
            @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@ScopeLocationId,
            @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@NewId, @LogEventTypeCode=N'DowntimeRecordedHistorical',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Approximate downtime recorded.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400); SET @NewId = NULL;
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeRecordedHistorical', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
