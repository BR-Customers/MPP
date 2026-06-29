-- ============================================================
-- Repeatable:  R__Lots_SortCage_MigrateSerial.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Re-containerizes a serialized part at the Sort Cage (Arc 2 Phase 7;
--              UJ-05 update-in-place). Writes a ContainerSerialHistory row capturing
--              Old/New container + tray, then updates ContainerSerial.ContainerId /
--              TrayPosition in place (genealogy + ShippingLabel chains stay valid --
--              backward trace from the serial still lands on the producing LOT).
--              Destination container must be Open (1). Audits 'ContainerSerialMigrated'.
--              No OUTPUT params; single terminal SELECT @Status,@Message,@NewId.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.SortCage_MigrateSerial
    @ContainerSerialId   BIGINT,
    @NewContainerId      BIGINT,
    @NewTrayPosition     INT          = NULL,
    @MigrationReasonCode NVARCHAR(50) = N'SortCage',
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @OldContainerId BIGINT, @OldTrayPosition INT, @NewConStatus BIGINT, @Activity NVARCHAR(500);

    BEGIN TRY
        IF @ContainerSerialId IS NULL OR @NewContainerId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerSerialId, NewContainerId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @OldContainerId = ContainerId, @OldTrayPosition = TrayPosition FROM Lots.ContainerSerial WHERE Id = @ContainerSerialId;
        IF @OldContainerId IS NULL
        BEGIN
            SET @Message = N'Container serial not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF @NewContainerId = @OldContainerId
        BEGIN
            SET @Message = N'Serial is already in the destination container.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        SELECT @NewConStatus = ContainerStatusCodeId FROM Lots.Container WHERE Id = @NewContainerId;
        IF @NewConStatus IS NULL
        BEGIN
            SET @Message = N'Destination container not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF @NewConStatus <> 1  -- 1 = Open
        BEGIN
            SET @Message = N'Destination container is not open.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(N'Serial #' + CAST(@ContainerSerialId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' ' + @MigrationReasonCode + N' ' + Audit.ufn_MidDot() + N' Migrated to container #' + CAST(@NewContainerId AS NVARCHAR(20)));

        BEGIN TRANSACTION;
        INSERT INTO Lots.ContainerSerialHistory
            (ContainerSerialId, OldContainerId, NewContainerId, OldTrayPosition, NewTrayPosition, MigrationReasonCode, MigratedByUserId)
        VALUES
            (@ContainerSerialId, @OldContainerId, @NewContainerId, @OldTrayPosition, @NewTrayPosition, @MigrationReasonCode, @AppUserId);
        SET @NewId = SCOPE_IDENTITY();

        UPDATE Lots.ContainerSerial
        SET ContainerId = @NewContainerId, ContainerTrayId = NULL, TrayPosition = @NewTrayPosition
        WHERE Id = @ContainerSerialId;

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ContainerSerialHistory', @EntityId = @NewId, @LogEventTypeCode = N'ContainerSerialMigrated',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = NULL;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Serial migrated.';
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
