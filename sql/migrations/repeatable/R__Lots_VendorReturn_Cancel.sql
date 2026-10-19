-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_Cancel.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5 (spec 5.3). Cancels a marked, not yet
--              confirmed vendor return and puts the taken quantity back on the
--              LOT: PieceCount += PieceCountTaken, InventoryAvailable +=
--              InventoryTaken -- exactly what Mark removed, so a return that
--              exceeded InventoryAvailable restores to the same figures.
--
--              Refused when the return is already confirmed or cancelled, or
--              when the LOT is Closed / Scrap / Open (a LOT that Mark closed at
--              zero is therefore not reopened here). A Hold LOT may be
--              restored and stays Hold.
--
--              Concurrency: the Lot row is taken under UPDLOCK, HOLDLOCK and
--              the open state is re-checked inside the transaction with a
--              conditional UPDATE + @@ROWCOUNT (routed to CATCH, never a
--              ROLLBACK inside an INSERT-EXEC-captured call), so two
--              concurrent cancels cannot both restore quantity.
--              Single terminal row: Status, Message.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.VendorReturn_Cancel
    @VendorReturnId     BIGINT,
    @CancelRemarks      NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.VendorReturn_Cancel';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @VendorReturnId AS VendorReturnId, @CancelRemarks AS CancelRemarks,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @Qty INT, @PcTaken INT, @InvTaken INT;
    DECLARE @ConfAt DATETIME2(3), @CancAt DATETIME2(3);
    DECLARE @StatusCode NVARCHAR(20), @StatusName NVARCHAR(100);

    BEGIN TRY
        IF (@VendorReturnId IS NULL) OR (@AppUserId IS NULL)
        BEGIN
            SET @Message = N'Required parameter missing (VendorReturnId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LotId = vr.LotId, @LotName = l.LotName, @Qty = vr.Quantity,
               @PcTaken = vr.PieceCountTaken, @InvTaken = vr.InventoryTaken,
               @ConfAt = vr.ConfirmedAt, @CancAt = vr.CancelledAt,
               @StatusCode = sc.Code, @StatusName = sc.Name
        FROM Lots.VendorReturn vr
        INNER JOIN Lots.Lot l ON l.Id = vr.LotId
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE vr.Id = @VendorReturnId;

        IF (@LotId IS NULL)
            SET @Message = N'Vendor return not found.';
        ELSE IF (@CancelRemarks IS NULL) OR (LTRIM(RTRIM(@CancelRemarks)) = N'')
            SET @Message = N'A reason is required to cancel a vendor return.';
        ELSE IF (@ConfAt IS NOT NULL)
            SET @Message = N'This vendor return was already confirmed and cannot be cancelled.';
        ELSE IF (@CancAt IS NOT NULL)
            SET @Message = N'This vendor return was already cancelled.';
        ELSE IF (@StatusCode IN (N'Closed', N'Scrap', N'Open'))
            SET @Message = N'LOT ' + @LotName + N' is ' + @StatusName + N' (status ' + @StatusCode + N'); the returned quantity cannot be restored.';
        ELSE
            SET @Message = NULL;

        IF @Message IS NOT NULL
        BEGIN
            IF @LotId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnCancelled',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        -- Take the Lot row first (same lock order as Mark), then claim the
        -- return with a conditional UPDATE: only one of two concurrent cancels
        -- sees @@ROWCOUNT = 1.
        DECLARE @NewPieceCount INT;
        UPDATE l
        SET @NewPieceCount       = l.PieceCount + @PcTaken,
            l.PieceCount         = l.PieceCount + @PcTaken,
            l.InventoryAvailable = l.InventoryAvailable + @InvTaken,
            l.UpdatedAt          = SYSUTCDATETIME(),
            l.UpdatedByUserId    = @AppUserId
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.Id = @LotId
          AND EXISTS (SELECT 1 FROM Lots.VendorReturn vr
                      WHERE vr.Id = @VendorReturnId AND vr.ConfirmedAt IS NULL AND vr.CancelledAt IS NULL);

        IF @@ROWCOUNT = 0
            RAISERROR(N'The vendor return is no longer open (concurrent update). Reload and retry.', 16, 1);

        UPDATE Lots.VendorReturn
        SET CancelledAt = SYSUTCDATETIME(), CancelledByUserId = @AppUserId, CancelRemarks = @CancelRemarks
        WHERE Id = @VendorReturnId AND ConfirmedAt IS NULL AND CancelledAt IS NULL;

        IF @@ROWCOUNT = 0
            RAISERROR(N'The vendor return is no longer open (concurrent update). Reload and retry.', 16, 1);

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LotName + N' ' + Audit.ufn_MidDot() + N' Vendor return ' + Audit.ufn_MidDot()
            + N' Cancelled ' + CAST(@Qty AS NVARCHAR(20)) + N' pcs; restored to ' + CAST(@NewPieceCount AS NVARCHAR(20)));
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT vr.Id AS VendorReturnId, vr.Quantity, vr.PieceCountTaken, vr.InventoryTaken, vr.CancelRemarks,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                               FROM Lots.Lot l WHERE l.Id = vr.LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot
            FROM Lots.VendorReturn vr WHERE vr.Id = @VendorReturnId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'VendorReturnCancelled',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Vendor return cancelled; ' + CAST(@PcTaken AS NVARCHAR(20)) + N' pieces restored to the LOT.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnCancelled',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
