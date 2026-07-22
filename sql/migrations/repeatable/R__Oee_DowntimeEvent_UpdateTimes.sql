-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_UpdateTimes.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-21
-- Version:     1.0
-- Description: Retroactively corrects a downtime event's start/end (and optionally
--              remarks) from the Downtime Manager popup (Increment 1). Inputs are
--              ET wall-clock (the picker's Date is formatted to
--              'yyyy-MM-dd HH:mm:ss' ET in Python, arrives as DATETIME2 with no tz),
--              converted ET->UTC at the boundary. @EndedAtEt NULL leaves the event
--              open. Validates end>start; rejects voided; guards the one-open-per-
--              location invariant when re-opening. @Remarks COALESCEs (NULL keeps).
--              Audits 'DowntimeTimesEdited' with Old/New ET times. Returns
--              SELECT @Status, @Message. All rejects before BEGIN TRANSACTION.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_UpdateTimes
    @DowntimeEventId    BIGINT,
    @StartedAtEt        DATETIME2(3),
    @EndedAtEt          DATETIME2(3)  = NULL,
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_UpdateTimes';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @DowntimeEventId AS DowntimeEventId, @StartedAtEt AS StartedAtEt,
               @EndedAtEt AS EndedAtEt, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocationId BIGINT, @LocCode NVARCHAR(50), @VoidedAt DATETIME2(3),
            @OldStartUtc DATETIME2(3), @OldEndUtc DATETIME2(3);

    BEGIN TRY
        IF @DowntimeEventId IS NULL OR @AppUserId IS NULL OR @StartedAtEt IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (DowntimeEventId, StartedAtEt, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF @EndedAtEt IS NOT NULL AND @EndedAtEt <= @StartedAtEt
        BEGIN
            SET @Message = N'End time must be after start time.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @LocationId = de.LocationId, @VoidedAt = de.VoidedAt,
               @OldStartUtc = de.StartedAt, @OldEndUtc = de.EndedAt
        FROM Oee.DowntimeEvent de WHERE de.Id = @DowntimeEventId;

        IF @LocationId IS NULL
        BEGIN
            SET @Message = N'Downtime event not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeTimesEdited', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF @VoidedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot edit a voided event.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeTimesEdited', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @StartUtc DATETIME2(3) = CAST(@StartedAtEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
        DECLARE @EndUtc   DATETIME2(3) = CASE WHEN @EndedAtEt IS NULL THEN NULL
                                              ELSE CAST(@EndedAtEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END;

        -- One-open invariant: re-opening (EndUtc NULL) must not collide with another open event here.
        IF @EndUtc IS NULL AND EXISTS (SELECT 1 FROM Oee.DowntimeEvent
                                       WHERE LocationId = @LocationId AND EndedAt IS NULL AND Id <> @DowntimeEventId)
        BEGIN
            SET @Message = N'Another open downtime event already exists at this location.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeTimesEdited', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Times edited');
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT CONVERT(NVARCHAR(30), @OldStartUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time', 126) AS StartedAtEt,
                   CONVERT(NVARCHAR(30), @OldEndUtc   AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time', 126) AS EndedAtEt
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT CONVERT(NVARCHAR(30), @StartedAtEt, 126) AS StartedAtEt,
                   CONVERT(NVARCHAR(30), @EndedAtEt, 126)   AS EndedAtEt,
                   @Remarks AS Remarks
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        UPDATE Oee.DowntimeEvent
        SET StartedAt = @StartUtc,
            EndedAt   = @EndUtc,
            Remarks   = COALESCE(@Remarks, Remarks)
        WHERE Id = @DowntimeEventId;
        EXEC Audit.Audit_LogOperation
            @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@LocationId,
            @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId, @LogEventTypeCode=N'DowntimeTimesEdited',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=@OldValue, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Times updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeTimesEdited', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
