-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_Void.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Voids a container shipping label (Arc 2 Phase 7; used at Sort Cage
--              re-pack). Marks IsVoid=1 + VoidedAt + VoidedByUserId; rejects an
--              already-void label. Audits 'ShippingLabelVoided'. No OUTPUT params;
--              single terminal SELECT @Status,@Message.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.ShippingLabel_Void
    @ShippingLabelId    BIGINT,
    @VoidReason         NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @IsVoid BIT, @ContainerId BIGINT, @Activity NVARCHAR(500);

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
        SELECT @IsVoid = IsVoid, @ContainerId = ContainerId FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId;
        IF @ContainerId IS NULL
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
        IF @IsVoid = 1
        BEGIN
            SET @Message = N'Shipping label is already void.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(N'Shipping label #' + CAST(@ShippingLabelId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Voided');

        BEGIN TRANSACTION;
        UPDATE Lots.ShippingLabel SET IsVoid = 1, VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @AppUserId WHERE Id = @ShippingLabelId;
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ShippingLabel', @EntityId = @ShippingLabelId, @LogEventTypeCode = N'ShippingLabelVoided',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = NULL;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shipping label voided.';
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
