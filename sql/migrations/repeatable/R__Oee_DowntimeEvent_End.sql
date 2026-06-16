-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_End.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Closes an open downtime event (Arc 2 Phase 8). Validates the event
--              exists + is open (EndedAt IS NULL); rejects an already-closed
--              event. Sets EndedAt, optional Remarks, and stamps AppUserId when
--              the event was opened without one (PLC-driven). Audits
--              'DowntimeEnded' to Audit.OperationLog with the resolved Location +
--              duration. Returns SELECT @Status, @Message. No OUTPUT params.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_End
    @DowntimeEventId    BIGINT,
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_End';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @DowntimeEventId AS DowntimeEventId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocationId BIGINT, @LocCode NVARCHAR(50), @StartedAt DATETIME2(3), @EndedAt DATETIME2(3);

    BEGIN TRY
        IF @DowntimeEventId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (DowntimeEventId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LocationId = de.LocationId, @StartedAt = de.StartedAt, @EndedAt = de.EndedAt
        FROM Oee.DowntimeEvent de WHERE de.Id = @DowntimeEventId;

        IF @LocationId IS NULL
        BEGIN
            SET @Message = N'Downtime event not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeEnded', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @EndedAt IS NOT NULL
        BEGIN
            SET @Message = N'Downtime event is already closed.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeEnded', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId;
        DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
        DECLARE @DurationMin INT = DATEDIFF(MINUTE, @StartedAt, @Now);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot()
            + N' Ended (' + CAST(@DurationMin AS NVARCHAR(20)) + N' min)';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (SELECT CAST(NULL AS NVARCHAR(30)) AS EndedAt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT CONVERT(NVARCHAR(30), @Now, 126) AS EndedAt, @Remarks AS Remarks FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Oee.DowntimeEvent
        SET EndedAt   = @Now,
            Remarks   = @Remarks,
            AppUserId = COALESCE(AppUserId, @AppUserId)
        WHERE Id = @DowntimeEventId;

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LocationId,
            @LogEntityTypeCode  = N'DowntimeEvent',
            @EntityId           = @DowntimeEventId,
            @LogEventTypeCode   = N'DowntimeEnded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Downtime ended.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeEnded', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
