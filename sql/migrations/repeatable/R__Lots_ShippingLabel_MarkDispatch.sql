-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_MarkDispatch.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Brief D (FAT-ENV-170 / FAT-LBL-150) -- record the outcome of one
--   shipping-label dispatch cycle from the Gateway-async dispatcher.
--     @Success = 1 -> set PrintedAt, bump PrintAttempts, stamp LastPrintAttemptAt,
--                     clear LastPrintError.
--     @Success = 0 -> bump PrintAttempts, stamp LastPrintAttemptAt + LastPrintError;
--                     when PrintAttempts reaches @MaxAttempts, stamp PrintFailedAt
--                     (drives the stranded-sweep escalation + the terminal banner).
--   No OUTPUT params; single terminal status row (FDS-11-011). Validations before
--   BEGIN TRANSACTION (INSERT-EXEC / Msg-3915 safe).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_MarkDispatch
    @ShippingLabelId BIGINT,
    @Success         BIT,
    @ErrorText       NVARCHAR(500) = NULL,
    @MaxAttempts     INT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @Success IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, Success).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId)
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;
        UPDATE Lots.ShippingLabel
        SET PrintAttempts      = PrintAttempts + 1,
            LastPrintAttemptAt = SYSUTCDATETIME(),
            PrintedAt          = CASE WHEN @Success = 1 THEN SYSUTCDATETIME() ELSE PrintedAt END,
            LastPrintError     = CASE WHEN @Success = 1 THEN NULL ELSE @ErrorText END,
            PrintFailedAt      = CASE WHEN @Success = 0 AND (PrintAttempts + 1) >= @MaxAttempts
                                      THEN SYSUTCDATETIME() ELSE PrintFailedAt END
        WHERE Id = @ShippingLabelId;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CASE WHEN @Success = 1 THEN N'Dispatch recorded (printed).'
                            ELSE N'Dispatch failure recorded.' END;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
