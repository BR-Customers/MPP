-- ============================================================
-- Repeatable:  R__Lots_LotLabel_RecordDispatch.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (Spec 2 sec 4). Dispatch-ack write-back: the gateway
--              records that a LotLabel's ZPL reached the printer. Sets PrinterName
--              + DispatchedAt = SYSUTCDATETIME() on the existing append-only row.
--              Status-row proc (NQ type=Query). No audit row here -- the dispatch
--              attempt itself logs to Audit.InterfaceLog via the entity script +
--              Audit_LogInterfaceCall. No OUTPUT params; RAISERROR (not THROW).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LotLabel_RecordDispatch
    @LotLabelId  BIGINT,
    @PrinterName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @LotLabelId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotLabelId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.LotLabel WHERE Id = @LotLabelId)
        BEGIN
            SET @Message = N'LotLabel not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        UPDATE Lots.LotLabel
        SET PrinterName  = @PrinterName,
            DispatchedAt = SYSUTCDATETIME()
        WHERE Id = @LotLabelId;

        SET @Status  = 1;
        SET @Message = N'Dispatch recorded.';
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
