-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_Void.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-21
-- Version:     1.0
-- Description: Soft-voids a downtime event from the Downtime Manager popup
--              (Increment 1) -- append-only convention, no hard delete. Sets
--              VoidedAt/VoidedByUserId/VoidReason; if the event is still open it is
--              also closed (EndedAt = now) so it frees the one-open-per-location
--              slot. Rejects a double-void. Voided events remain visible in reads
--              (IsVoided=1) and are excluded from future rollups. Audits
--              'DowntimeVoided' (Warning). Returns SELECT @Status, @Message.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_Void
    @DowntimeEventId    BIGINT,
    @VoidReason         NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_Void';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @DowntimeEventId AS DowntimeEventId, @VoidReason AS VoidReason, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocationId BIGINT, @LocCode NVARCHAR(50), @VoidedAt DATETIME2(3), @EndedAt DATETIME2(3);

    BEGIN TRY
        IF @DowntimeEventId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (DowntimeEventId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @LocationId = de.LocationId, @VoidedAt = de.VoidedAt, @EndedAt = de.EndedAt
        FROM Oee.DowntimeEvent de WHERE de.Id = @DowntimeEventId;

        IF @LocationId IS NULL
        BEGIN
            SET @Message = N'Downtime event not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeVoided', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF @VoidedAt IS NOT NULL
        BEGIN
            SET @Message = N'Downtime event is already voided.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeVoided', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId;
        DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Voided');
        DECLARE @OldValue NVARCHAR(MAX) = (SELECT CAST(NULL AS NVARCHAR(30)) AS VoidedAt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT CONVERT(NVARCHAR(30), @Now, 126) AS VoidedAt, @VoidReason AS VoidReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        UPDATE Oee.DowntimeEvent
        SET VoidedAt       = @Now,
            VoidedByUserId = @AppUserId,
            VoidReason     = @VoidReason,
            EndedAt        = COALESCE(EndedAt, @Now)   -- close if still open (frees the one-open slot)
        WHERE Id = @DowntimeEventId;
        EXEC Audit.Audit_LogOperation
            @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@LocationId,
            @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId, @LogEventTypeCode=N'DowntimeVoided',
            @LogSeverityCode=N'Warning', @Description=@Activity, @OldValue=@OldValue, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Downtime voided.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeVoided', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
