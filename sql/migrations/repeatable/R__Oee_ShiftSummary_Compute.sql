-- =============================================
-- Procedure:   Oee.ShiftSummary_Compute
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   Computes and stores one CLOSED shift's OEE figures in Oee.ShiftSummary
--   (OEE dashboard spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--   v0.3.1 sec 6.7). Replaces the shift's rows in one transaction via
--   Oee.ShiftSummary_ComputeCore. Refuses an unknown shift and the shift in
--   progress (ActualEnd NULL): the shift in progress is never stored -- the
--   dashboard computes it live.
--
--   Refusals run before BEGIN TRANSACTION (CLAUDE.md INSERT-EXEC rule). No
--   audit: the summary is derived data, recomputable from the audited source
--   rows at any time.
--
-- Parameters:
--   @ShiftId   BIGINT - required.
--   @AppUserId BIGINT - required (who asked; the gateway passes the SYS user).
--
-- Result set: Status BIT, Message NVARCHAR(500).
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftSummary_Compute
    @ShiftId   BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @ShiftId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'ShiftId and AppUserId are required.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @ShiftId)
        BEGIN
            SET @Message = N'Shift not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @ShiftId AND ActualEnd IS NULL)
        BEGIN
            SET @Message = N'The shift is still in progress; its figures are computed live, not stored.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;
        EXEC Oee.ShiftSummary_ComputeCore @ShiftId = @ShiftId;
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shift figures computed.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 AND XACT_STATE() = -1 ROLLBACK TRANSACTION;
        SET @Message = N'Oee.ShiftSummary_Compute: ' + ERROR_MESSAGE();
        SELECT @Status AS Status, @Message AS Message;
        DECLARE @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        RAISERROR(@Message, @ErrSev, @ErrState);
    END CATCH
END;
GO
