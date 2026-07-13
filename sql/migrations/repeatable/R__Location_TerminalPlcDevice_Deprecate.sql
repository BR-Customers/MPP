-- =============================================
-- Procedure:   Location.TerminalPlcDevice_Deprecate
-- Description: Soft-delete a terminal->PLC-device mapping (sets DeprecatedAt).
-- Result set: Status BIT, Message NVARCHAR(500).
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.TerminalPlcDevice_Deprecate';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @DeviceCode NVARCHAR(100);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @DeviceCode = DeviceCode FROM Location.TerminalPlcDevice WHERE Id=@Id AND DeprecatedAt IS NULL;
        IF @DeviceCode IS NULL
        BEGIN
            SET @Message = N'TerminalPlcDevice not found or already deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Terminal device ' + @DeviceCode + N' ' + Audit.ufn_MidDot() + N' Deprecated');

        BEGIN TRANSACTION;
        UPDATE Location.TerminalPlcDevice
        SET DeprecatedAt=SYSUTCDATETIME(), UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId
        WHERE Id=@Id;

        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
            @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=NULL;
        COMMIT TRANSACTION;

        SET @Status=1; SET @Message=N'Terminal device deprecated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
