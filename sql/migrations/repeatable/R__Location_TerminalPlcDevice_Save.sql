-- =============================================
-- Procedure:   Location.TerminalPlcDevice_Save
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Upsert a terminal->UDT-instance pointer row. @Id NULL = insert,
--   non-null = update. Validates terminal exists + is a Terminal (DefId 7),
--   device type exists, DeviceCode unique among the terminal's active devices.
--   Auto-assigns SortOrder = MAX(active peers)+1 on insert. OPC addressing is
--   NOT stored here - it lives on the UDT instance's params in the tag provider.
-- Result set: Status BIT, Message NVARCHAR(500), NewId BIGINT.
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_Save
    @Id                  BIGINT        = NULL,
    @TerminalLocationId  BIGINT,
    @PlcDeviceTypeId     BIGINT,
    @DeviceCode          NVARCHAR(100),
    @UdtInstancePath     NVARCHAR(400),
    @SortOrder           INT           = NULL,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Location.TerminalPlcDevice_Save';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @TerminalLocationId AS TerminalLocationId, @PlcDeviceTypeId AS PlcDeviceTypeId,
                @DeviceCode AS DeviceCode, @UdtInstancePath AS UdtInstancePath
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @TerminalLocationId IS NULL OR @PlcDeviceTypeId IS NULL OR @DeviceCode IS NULL
           OR @UdtInstancePath IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Terminal must exist, be active, and be a Terminal (LocationTypeDefinitionId 7)
        IF NOT EXISTS (SELECT 1 FROM Location.Location
                       WHERE Id=@TerminalLocationId AND DeprecatedAt IS NULL AND LocationTypeDefinitionId=7)
        BEGIN
            SET @Message = N'TerminalLocationId is not an active Terminal location.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType WHERE Id=@PlcDeviceTypeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'PlcDeviceTypeId not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- DeviceCode unique among the terminal's active devices (excluding the row being updated)
        IF EXISTS (SELECT 1 FROM Location.TerminalPlcDevice
                   WHERE TerminalLocationId=@TerminalLocationId AND DeviceCode=@DeviceCode
                     AND DeprecatedAt IS NULL AND (@Id IS NULL OR Id <> @Id))
        BEGIN
            SET @Message = N'A device with this DeviceCode already exists on this terminal.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Terminal device ' + @DeviceCode + N' ' + Audit.ufn_MidDot()
            + CASE WHEN @Id IS NULL THEN N' Created' ELSE N' Updated' END
            + N' (' + @UdtInstancePath + N')');

        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Next INT = COALESCE(@SortOrder,
                (SELECT ISNULL(MAX(SortOrder),0)+1 FROM Location.TerminalPlcDevice
                 WHERE TerminalLocationId=@TerminalLocationId AND DeprecatedAt IS NULL));

            INSERT INTO Location.TerminalPlcDevice
                (TerminalLocationId, PlcDeviceTypeId, DeviceCode, UdtInstancePath, SortOrder, CreatedAt)
            VALUES
                (@TerminalLocationId, @PlcDeviceTypeId, @DeviceCode, @UdtInstancePath, @Next, SYSUTCDATETIME());

            SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

            EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@NewId, @LogEventTypeCode=N'Created', @LogSeverityCode=N'Info',
                @Description=@Activity, @OldValue=NULL, @NewValue=@Params;

            SET @Message = N'Terminal device created.';
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Location.TerminalPlcDevice WHERE Id=@Id AND DeprecatedAt IS NULL)
                RAISERROR(N'TerminalPlcDevice Id not found or deprecated.', 16, 1);

            UPDATE Location.TerminalPlcDevice
            SET PlcDeviceTypeId=@PlcDeviceTypeId, DeviceCode=@DeviceCode,
                UdtInstancePath=@UdtInstancePath,
                SortOrder=COALESCE(@SortOrder, SortOrder),
                UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId
            WHERE Id=@Id;

            SET @NewId = @Id;

            EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
                @Description=@Activity, @OldValue=NULL, @NewValue=@Params;

            SET @Message = N'Terminal device updated.';
        END

        COMMIT TRANSACTION;
        SET @Status = 1;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400); SET @NewId=NULL;
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
