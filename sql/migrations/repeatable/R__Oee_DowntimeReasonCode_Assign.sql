-- ============================================================
-- Repeatable:  R__Oee_DowntimeReasonCode_Assign.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Late-binds a reason code to an OPEN downtime event (Arc 2 Phase 8,
--              B7). Used when the PLC opened the event with no reason. Validates
--              the event exists + is open; REFUSES to overwrite an
--              already-assigned reason (B7 -- supervisors correct via other
--              means). Audits 'DowntimeReasonAssigned' (NULL -> resolved
--              DowntimeReasonCode). Returns SELECT @Status, @Message.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Assign
    @DowntimeEventId      BIGINT,
    @DowntimeReasonCodeId BIGINT,
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeReasonCode_Assign';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @DowntimeEventId AS DowntimeEventId, @DowntimeReasonCodeId AS DowntimeReasonCodeId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocationId BIGINT, @LocCode NVARCHAR(50), @EndedAt DATETIME2(3), @ExistingReason BIGINT;

    BEGIN TRY
        IF @DowntimeEventId IS NULL OR @DowntimeReasonCodeId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (DowntimeEventId, DowntimeReasonCodeId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LocationId = de.LocationId, @EndedAt = de.EndedAt, @ExistingReason = de.DowntimeReasonCodeId
        FROM Oee.DowntimeEvent de WHERE de.Id = @DowntimeEventId;

        IF @LocationId IS NULL
        BEGIN
            SET @Message = N'Downtime event not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeReasonAssigned', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @EndedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot assign a reason to a closed downtime event.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeReasonAssigned', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- B7: refuse to overwrite an already-assigned reason ----
        IF @ExistingReason IS NOT NULL
        BEGIN
            SET @Message = N'Reason already assigned; cannot overwrite (B7).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeReasonAssigned', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Id = @DowntimeReasonCodeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Reason code not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = @DowntimeEventId,
                @LogEventTypeCode = N'DowntimeReasonAssigned', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId;

        DECLARE @ReasonCode NVARCHAR(20) = (SELECT Code FROM Oee.DowntimeReasonCode WHERE Id = @DowntimeReasonCodeId);
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot()
            + N' Reason assigned ' + @ReasonCode;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (SELECT CAST(NULL AS NVARCHAR(20)) AS DowntimeReasonCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT rc.Id, rc.Code, rc.Description AS Name FROM Oee.DowntimeReasonCode rc
                               WHERE rc.Id = @DowntimeReasonCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Oee.DowntimeEvent SET DowntimeReasonCodeId = @DowntimeReasonCodeId WHERE Id = @DowntimeEventId;

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LocationId,
            @LogEntityTypeCode  = N'DowntimeEvent',
            @EntityId           = @DowntimeEventId,
            @LogEventTypeCode   = N'DowntimeReasonAssigned',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Reason assigned.';
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
                @LogEventTypeCode = N'DowntimeReasonAssigned', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
