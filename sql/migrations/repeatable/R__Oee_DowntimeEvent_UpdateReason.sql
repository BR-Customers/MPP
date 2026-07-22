-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_UpdateReason.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-21
-- Version:     1.0
-- Description: Changes (or clears) a downtime event's reason from the Downtime
--              Manager popup (Increment 1). Unlike B7 Oee.DowntimeReasonCode_Assign
--              (which REFUSES to overwrite and stays for the PLC late-bind path),
--              this ALLOWS changing an already-set reason. Rejects a voided event.
--              Audits 'DowntimeReasonChanged' to Audit.OperationLog with resolved
--              Old/New reason sub-objects. Returns SELECT @Status, @Message. No
--              OUTPUT params (FDS-11-011). All rejects run BEFORE BEGIN TRANSACTION.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_UpdateReason
    @DowntimeEventId      BIGINT,
    @DowntimeReasonCodeId BIGINT,          -- NULL clears the reason
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_UpdateReason';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @DowntimeEventId AS DowntimeEventId, @DowntimeReasonCodeId AS DowntimeReasonCodeId,
               @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocationId BIGINT, @LocCode NVARCHAR(50), @OldReasonId BIGINT, @VoidedAt DATETIME2(3);

    BEGIN TRY
        IF @DowntimeEventId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (DowntimeEventId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @LocationId = de.LocationId, @OldReasonId = de.DowntimeReasonCodeId, @VoidedAt = de.VoidedAt
        FROM Oee.DowntimeEvent de WHERE de.Id = @DowntimeEventId;

        IF @LocationId IS NULL
        BEGIN
            SET @Message = N'Downtime event not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeReasonChanged', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF @VoidedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot edit a voided event.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeReasonChanged', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF @DowntimeReasonCodeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Id = @DowntimeReasonCodeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Reason code not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeReasonChanged', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Reason changed');
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT rc.Id, rc.Code, rc.Description AS Name FROM Oee.DowntimeReasonCode rc
                               WHERE rc.Id = @OldReasonId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT rc.Id, rc.Code, rc.Description AS Name FROM Oee.DowntimeReasonCode rc
                               WHERE rc.Id = @DowntimeReasonCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        UPDATE Oee.DowntimeEvent SET DowntimeReasonCodeId = @DowntimeReasonCodeId WHERE Id = @DowntimeEventId;
        EXEC Audit.Audit_LogOperation
            @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@LocationId,
            @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId, @LogEventTypeCode=N'DowntimeReasonChanged',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=@OldValue, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Reason updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@DowntimeEventId,
                @LogEventTypeCode=N'DowntimeReasonChanged', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
