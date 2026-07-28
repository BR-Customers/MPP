-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_RecordDispatch.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     1.0
-- Description: Dispatch write-back for a container shipping label (design 2026-07-28
--              sec 3.7). Mirrors Lots.LotLabel_RecordDispatch.
--                @Success = 1 -> PrintedAt + LastPrintAttemptAt set, error cleared.
--                @Success = 0 -> PrintAttempts incremented, LastPrintAttemptAt and
--                                LastPrintError stored; PrintFailedAt set once
--                                attempts reach @MaxAttempts (FDS-07-006a: 3).
--              These five columns exist since 0028 and NOTHING wrote them until now;
--              the FDS-07-006b stranded-print sweep reads them, so populating them is
--              what makes that sweep buildable later (the sweep itself is out of scope).
--              Status-row proc (NQ type=Query). No audit row -- the dispatch attempt
--              logs to Audit.InterfaceLog via the entity script. No OUTPUT params;
--              RAISERROR (not THROW) in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId BIGINT,
    @Success         BIT,
    @ErrorText       NVARCHAR(500) = NULL,
    @MaxAttempts     INT           = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @Success IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, Success).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId)
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @Success = 1
        BEGIN
            UPDATE Lots.ShippingLabel
            SET PrintedAt          = SYSUTCDATETIME(),
                LastPrintAttemptAt = SYSUTCDATETIME(),
                LastPrintError     = NULL,
                PrintFailedAt      = NULL
            WHERE Id = @ShippingLabelId;

            SET @Message = N'Print recorded.';
        END
        ELSE
        BEGIN
            UPDATE Lots.ShippingLabel
            SET PrintAttempts      = PrintAttempts + 1,
                LastPrintAttemptAt = SYSUTCDATETIME(),
                LastPrintError     = @ErrorText,
                PrintFailedAt      = CASE WHEN PrintAttempts + 1 >= @MaxAttempts
                                          THEN SYSUTCDATETIME() ELSE PrintFailedAt END
            WHERE Id = @ShippingLabelId;

            SET @Message = N'Print failure recorded.';
        END

        SET @Status = 1;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
