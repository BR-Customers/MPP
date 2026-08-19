-- ============================================================
-- Repeatable:  R__Lots_Container_ValidateCrt.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-18
-- Version:     1.0
-- Description: A second person has validated a container that completed under a
--              Controlled Run Tag. Clears the CRT flag on the container's
--              finished-good LOT(s), which releases the container's AIM Shipper ID
--              back to the normal post path (AimShipperIdPool_ListUnposted stops
--              excluding it). The POST itself is the Python caller's next step
--              (BlueRidge.Lots.Container.validateCrt calls AimPost.postOne after
--              this proc returns Status 1).
--
--              Clears EVERY tray LOT of the container, not one: a container carries one
--              FG LOT per tray (Lots.ContainerTray.FinishedGoodLotId is 1:1 with the
--              tray, UQ_ContainerTray_FinishedGoodLot), and the serial stays held while
--              ANY of them is CrtActive.
--
--              INSERT-EXEC: this proc returns a status row and is captured by
--              callers, so it must NOT EXEC Lots.Lot_ClearCrt - a nested status-row
--              proc would pollute the single result set and nesting INSERT-EXEC is
--              illegal. The flag clear below MIRRORS Lots.Lot_ClearCrt (same
--              CrtActive/UpdatedAt/UpdatedByUserId shape); keep them in step.
--
--              All rejects run BEFORE BEGIN TRANSACTION (Msg 3915). "Pending
--              validation" is the same test as Container_ListPendingValidation /
--              AimShipperIdPool_ListUnposted: any of the container's tray LOTs
--              still CrtActive. An unknown container and a container with nothing
--              left to clear both reject the same way (no distinct message needed
--              beyond "not pending validation").
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Container_ValidateCrt
    @ContainerId        BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Lots.Container_ValidateCrt';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ContainerId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId)
        BEGIN
            SET @Message = N'Container not found.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (
            SELECT 1 FROM Lots.ContainerTray ct
            JOIN Lots.Lot fgl ON fgl.Id = ct.FinishedGoodLotId
            WHERE ct.ContainerId = @ContainerId AND fgl.CrtActive = 1)
        BEGIN
            SET @Message = N'Container is not pending validation.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;

        -- MIRRORS Lots.Lot_ClearCrt (see header): clear the tag + attribution
        -- on every tray LOT of this container in one set-based UPDATE.
        UPDATE fgl
        SET fgl.CrtActive       = 0,
            fgl.UpdatedAt       = SYSUTCDATETIME(),
            fgl.UpdatedByUserId = @AppUserId
        FROM Lots.Lot fgl
        JOIN Lots.ContainerTray ct ON ct.FinishedGoodLotId = fgl.Id
        WHERE ct.ContainerId = @ContainerId AND fgl.CrtActive = 1;

        DECLARE @Descr NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Controlled Run Tag ' + Audit.ufn_MidDot() + N' Validated');

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId,
            @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
            @Description = @Descr, @OldValue = NULL, @NewValue = NULL;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Container validated.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container',
                @EntityId = @ContainerId, @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
