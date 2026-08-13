-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_AckBanner.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Brief D -- acknowledge (dismiss) a print-failure banner. Sets
--   BannerAcknowledgedAt so the label drops out of ShippingLabel_GetForBanner. No OUTPUT
--   params; single terminal status row (FDS-11-011); validations before BEGIN TRANSACTION.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_AckBanner
    @ShippingLabelId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId)
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;
        UPDATE Lots.ShippingLabel SET BannerAcknowledgedAt = SYSUTCDATETIME() WHERE Id = @ShippingLabelId;
        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Banner acknowledged.';
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
