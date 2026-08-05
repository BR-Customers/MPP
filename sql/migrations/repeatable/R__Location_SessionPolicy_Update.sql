-- =============================================
-- Procedure: Location.SessionPolicy_Update
-- Author:    Blue Ridge Automation
-- Description: Updates the single global session-policy row. Validates both
--              durations are 30..3600 seconds. Writes a resolved ConfigLog audit
--              row (SessionPolicy entity). No OUTPUT params; returns Status/Message.
-- =============================================
CREATE OR ALTER PROCEDURE Location.SessionPolicy_Update
    @OperatorPresenceTimeoutSeconds INT,
    @ElevationTimeoutSeconds        INT,
    @AppUserId                      BIGINT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.SessionPolicy_Update';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @OperatorPresenceTimeoutSeconds AS Op, @ElevationTimeoutSeconds AS Elev FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRY
        IF @AppUserId IS NULL OR @OperatorPresenceTimeoutSeconds IS NULL OR @ElevationTimeoutSeconds IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; SELECT @Status AS Status, @Message AS Message; RETURN; END

        IF @OperatorPresenceTimeoutSeconds NOT BETWEEN 30 AND 3600
           OR @ElevationTimeoutSeconds NOT BETWEEN 30 AND 3600
        BEGIN
            SET @Message = N'Timeouts must be between 30 and 3600 seconds.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'SessionPolicy',
                @EntityId=1, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @OldOp INT, @OldElev INT;
        SELECT TOP 1 @OldOp = OperatorPresenceTimeoutSeconds, @OldElev = ElevationTimeoutSeconds
        FROM Location.SessionPolicy ORDER BY Id;

        DECLARE @Arrow NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(CONCAT(
            CASE WHEN @OldOp <> @OperatorPresenceTimeoutSeconds THEN N', Operator presence ' + CAST(@OldOp AS NVARCHAR(10)) + N's ' + @Arrow + N' ' + CAST(@OperatorPresenceTimeoutSeconds AS NVARCHAR(10)) + N's' ELSE N'' END,
            CASE WHEN @OldElev <> @ElevationTimeoutSeconds THEN N', Elevation ' + CAST(@OldElev AS NVARCHAR(10)) + N's ' + @Arrow + N' ' + CAST(@ElevationTimeoutSeconds AS NVARCHAR(10)) + N's' ELSE N'' END),
            1, 2, N'');
        IF @Fields IS NULL OR @Fields = N'' SET @Fields = N'no changes';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(N'Session Policy ' + Audit.ufn_MidDot() + N' Updated ' + @Fields);
        DECLARE @OldJson NVARCHAR(MAX) = (SELECT @OldOp AS OperatorPresenceTimeoutSeconds, @OldElev AS ElevationTimeoutSeconds FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewJson NVARCHAR(MAX) = (SELECT @OperatorPresenceTimeoutSeconds AS OperatorPresenceTimeoutSeconds, @ElevationTimeoutSeconds AS ElevationTimeoutSeconds FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        UPDATE Location.SessionPolicy
        SET OperatorPresenceTimeoutSeconds = @OperatorPresenceTimeoutSeconds,
            ElevationTimeoutSeconds        = @ElevationTimeoutSeconds,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId;
        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'SessionPolicy',
            @EntityId=1, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldJson, @NewValue=@NewJson;
        COMMIT TRANSACTION;
        SET @Status = 1; SET @Message = N'Session policy updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'SessionPolicy',
            @EntityId=1, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
