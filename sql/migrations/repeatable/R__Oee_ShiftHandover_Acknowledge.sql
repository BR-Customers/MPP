-- ============================================================
-- Repeatable:  R__Oee_ShiftHandover_Acknowledge.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-17
-- Version:     1.0
-- Description: Records that an operator reviewed/acknowledged the Shift-end
--              Summary (FDS-09-015). Audit-only: writes 'ShiftHandoverAcknowledged'
--              to Audit.OperationLog (entity 'Shift'). No data mutation -- the
--              shift-time data is already committed by EndOfShiftEntry_Submit;
--              this just records the handover review for traceability.
--              Returns SELECT @Status, @Message. No OUTPUT params.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.ShiftHandover_Acknowledge
    @ShiftId            BIGINT,
    @CellLocationId     BIGINT = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.ShiftHandover_Acknowledge';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ShiftId AS ShiftId, @CellLocationId AS CellLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ShiftId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShiftId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @ShiftId)
        BEGIN
            SET @Message = N'Shift not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Shift', @EntityId=@ShiftId,
                @LogEventTypeCode=N'ShiftHandoverAcknowledged', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Shift ' + CAST(@ShiftId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Handover ' + Audit.ufn_MidDot() + N' Acknowledged');

        BEGIN TRANSACTION;
        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @CellLocationId,
            @LogEntityTypeCode  = N'Shift',
            @EntityId           = @ShiftId,
            @LogEventTypeCode   = N'ShiftHandoverAcknowledged',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = NULL;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Handover acknowledged.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Shift', @EntityId=@ShiftId,
                @LogEventTypeCode=N'ShiftHandoverAcknowledged', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
