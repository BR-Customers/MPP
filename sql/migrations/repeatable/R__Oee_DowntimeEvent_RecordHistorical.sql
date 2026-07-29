-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_RecordHistorical.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-21
-- Version:     1.0
-- Description: Inserts a fully-past (both times known) CLOSED downtime event from
--              the Downtime Manager popup (Increment 1) -- operator forgot to log
--              it live. Logs against @ScopeLocationId (the resolved line/press).
--              ET inputs -> UTC. Source = 'Operator'. Stamps the shift covering the
--              start. The one-open filtered-unique index does NOT fire (EndedAt set).
--              Audits 'DowntimeRecordedHistorical'. Returns SELECT @Status, @Message,
--              @NewId. All rejects before BEGIN TRANSACTION.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_RecordHistorical
    @ScopeLocationId      BIGINT,
    @StartedAtEt          DATETIME2(3),
    @EndedAtEt            DATETIME2(3),
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

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_RecordHistorical';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ScopeLocationId AS ScopeLocationId, @StartedAtEt AS StartedAtEt, @EndedAtEt AS EndedAtEt,
               @DowntimeReasonCodeId AS DowntimeReasonCodeId, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode NVARCHAR(50), @SourceId BIGINT, @ShiftId BIGINT;

    BEGIN TRY
        IF @ScopeLocationId IS NULL OR @StartedAtEt IS NULL OR @EndedAtEt IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ScopeLocationId, StartedAtEt, EndedAtEt, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
        IF @EndedAtEt <= @StartedAtEt
        BEGIN
            SET @Message = N'End time must be after start time.';
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

        SET @SourceId = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

        DECLARE @StartUtc DATETIME2(3) = CAST(@StartedAtEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
        DECLARE @EndUtc   DATETIME2(3) = CAST(@EndedAtEt   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

        -- Shift covering the start (NULL if none open/covering).
        SELECT TOP 1 @ShiftId = Id FROM Oee.Shift
        WHERE ActualStart <= @StartUtc AND (ActualEnd IS NULL OR ActualEnd >= @StartUtc)
        ORDER BY ActualStart DESC;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Recorded (historical)');
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @ScopeLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   JSON_QUERY((SELECT rc.Id, rc.Code, rc.Description AS Name FROM Oee.DowntimeReasonCode rc WHERE rc.Id = @DowntimeReasonCodeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode,
                   CONVERT(NVARCHAR(30), @StartedAtEt, 126) AS StartedAtEt,
                   CONVERT(NVARCHAR(30), @EndedAtEt, 126)   AS EndedAtEt,
                   @Remarks AS Remarks
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        INSERT INTO Oee.DowntimeEvent
            (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, AppUserId, Remarks)
        VALUES
            (@ScopeLocationId, @DowntimeReasonCodeId, @ShiftId, @StartUtc, @EndUtc, @SourceId, @AppUserId, @Remarks);
        SET @NewId = SCOPE_IDENTITY();
        EXEC Audit.Audit_LogOperation
            @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@ScopeLocationId,
            @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@NewId, @LogEventTypeCode=N'DowntimeRecordedHistorical',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Historical downtime recorded.';
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
