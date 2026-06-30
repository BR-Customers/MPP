-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_Reprint.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Reprints a container shipping label (Arc 2 Phase 7). Shipping labels
--              are append-only: this inserts a NEW row for the same container +
--              AimShipperId with Initial=0 + a PrintReasonCode (the original row is
--              unchanged). Audits 'ShippingLabelReprinted'. No OUTPUT params; single
--              terminal SELECT @Status,@Message,@NewId.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.ShippingLabel_Reprint
    @ShippingLabelId    BIGINT,
    @PrintReasonCode    NVARCHAR(50) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @ContainerId BIGINT, @AimShipperId NVARCHAR(50), @LabelTypeCodeId BIGINT, @Activity NVARCHAR(500);

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        SELECT @ContainerId = ContainerId, @AimShipperId = AimShipperId, @LabelTypeCodeId = LabelTypeCodeId
        FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId;
        IF @ContainerId IS NULL
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(N'Shipping label ' + Audit.ufn_MidDot() + N' container #' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Reprinted');

        BEGIN TRANSACTION;
        INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintReasonCode, PrintedByUserId, TerminalLocationId)
        VALUES (@ContainerId, @AimShipperId, @LabelTypeCodeId, 0, @PrintReasonCode, @AppUserId, @TerminalLocationId);
        SET @NewId = SCOPE_IDENTITY();
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ShippingLabel', @EntityId = @NewId, @LogEventTypeCode = N'ShippingLabelReprinted',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = NULL;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shipping label reprinted.';
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
