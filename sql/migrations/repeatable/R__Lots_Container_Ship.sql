-- ============================================================
-- Repeatable:  R__Lots_Container_Ship.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Ships a container at the Shipping Dock (Arc 2 Phase 7). Validates the
--              container is Complete (2), has NO open hold, and the shipping label is
--              not void; flips status -> Shipped (3); audits 'ContainerShipped'.
--              No OUTPUT params (FDS-11-011); single terminal SELECT @Status,@Message.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Container_Ship
    @ShippingLabelId    BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ContainerId BIGINT, @IsVoid BIT, @ConStatus BIGINT, @Activity NVARCHAR(500);

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @ContainerId = ContainerId, @IsVoid = IsVoid FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId;
        IF @ContainerId IS NULL
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
        IF @IsVoid = 1
        BEGIN
            SET @Message = N'Shipping label is void.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
        SELECT @ConStatus = ContainerStatusCodeId FROM Lots.Container WHERE Id = @ContainerId;
        IF @ConStatus <> 2  -- 2 = Complete
        BEGIN
            SET @Message = N'Container is not Complete (cannot ship).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
        IF EXISTS (SELECT 1 FROM Quality.HoldEvent WHERE ContainerId = @ContainerId AND ReleasedAt IS NULL)
        BEGIN
            SET @Message = N'Container is on hold (cannot ship).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(N'Container #' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Shipping ' + Audit.ufn_MidDot() + N' Shipped');

        BEGIN TRANSACTION;
        UPDATE Lots.Container SET ContainerStatusCodeId = 3 WHERE Id = @ContainerId;  -- 3 = Shipped
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerShipped',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = NULL;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container shipped.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
