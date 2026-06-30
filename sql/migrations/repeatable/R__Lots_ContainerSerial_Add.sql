-- ============================================================
-- Repeatable:  R__Lots_ContainerSerial_Add.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Places a SerializedPart into a Container tray position (Arc 2
--              Phase 6 assembly). HardwareInterlockBypassed=1 records a per-piece
--              MES-validation bypass (UJ-16). A SerializedPart can only be placed
--              once (UNIQUE on SerializedPartId) -- a re-add rejects. Audits
--              'ContainerSerialAdded'. No OUTPUT params (FDS-11-011); single
--              terminal SELECT @Status,@Message,@NewId. RAISERROR in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.ContainerSerial_Add
    @ContainerId               BIGINT,
    @ContainerTrayId           BIGINT = NULL,
    @TrayPosition              INT    = NULL,
    @SerializedPartId          BIGINT,
    @HardwareInterlockBypassed BIT    = 0,
    @AppUserId                 BIGINT = NULL,
    @TerminalLocationId        BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerSerial_Add';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @SerializedPartId AS SerializedPartId,
               @HardwareInterlockBypassed AS HardwareInterlockBypassed, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Serial NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500);
    DECLARE @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @ContainerId IS NULL OR @SerializedPartId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerId, SerializedPartId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId)
        BEGIN
            SET @Message = N'Container not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        SELECT @Serial = SerialNumber FROM Lots.SerializedPart WHERE Id = @SerializedPartId;
        IF @Serial IS NULL
        BEGIN
            SET @Message = N'Serialized part not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF @ContainerTrayId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Lots.ContainerTray WHERE Id = @ContainerTrayId AND ContainerId = @ContainerId)
        BEGIN
            SET @Message = N'Container tray not found for this container.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Business rule: a serial is placed at most once ----
        IF EXISTS (SELECT 1 FROM Lots.ContainerSerial WHERE SerializedPartId = @SerializedPartId)
        BEGIN
            SET @Message = N'Serialized part ' + @Serial + N' is already placed in a container.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerSerial', @EntityId = NULL,
                @LogEventTypeCode = N'ContainerSerialAdded', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(@Serial + N' ' + Audit.ufn_MidDot() + N' Container Serial ' + Audit.ufn_MidDot()
            + CASE WHEN @HardwareInterlockBypassed = 1 THEN N' Added (interlock bypassed)' ELSE N' Added' END);
        SET @NewValue = (
            SELECT @ContainerId AS ContainerId, @ContainerTrayId AS ContainerTrayId, @TrayPosition AS TrayPosition,
                   JSON_QUERY((SELECT sp.Id, sp.SerialNumber AS Code FROM Lots.SerializedPart sp WHERE sp.Id = @SerializedPartId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS SerializedPart,
                   @HardwareInterlockBypassed AS HardwareInterlockBypassed
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed)
        VALUES (@ContainerId, @ContainerTrayId, @SerializedPartId, @TrayPosition, @HardwareInterlockBypassed);

        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ContainerSerial', @EntityId = @NewId, @LogEventTypeCode = N'ContainerSerialAdded',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Serialized part ' + @Serial + N' added to container.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();

        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId = NULL;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
