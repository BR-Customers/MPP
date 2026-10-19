-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_Confirm.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5 (spec 5.2). Confirms a marked vendor return
--              as shipped back. Stamps ConfirmedAt/ConfirmedByUserId only --
--              the quantity already left the LOT at Mark. A return can be
--              confirmed once, and not after it was cancelled.
--              Single terminal row: Status, Message.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.VendorReturn_Confirm
    @VendorReturnId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.VendorReturn_Confirm';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @VendorReturnId AS VendorReturnId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @Qty INT, @ConfAt DATETIME2(3), @CancAt DATETIME2(3);

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
               @ConfAt = vr.ConfirmedAt, @CancAt = vr.CancelledAt
        FROM Lots.VendorReturn vr
        INNER JOIN Lots.Lot l ON l.Id = vr.LotId
        WHERE vr.Id = @VendorReturnId;

        IF (@LotId IS NULL)
            SET @Message = N'Vendor return not found.';
        ELSE IF (@ConfAt IS NOT NULL)
            SET @Message = N'This vendor return was already confirmed.';
        ELSE IF (@CancAt IS NOT NULL)
            SET @Message = N'This vendor return was cancelled and cannot be confirmed.';
        ELSE
            SET @Message = NULL;

        IF @Message IS NOT NULL
        BEGIN
            IF @LotId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnConfirmed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        -- Conditional UPDATE: only an open row is stamped, so two concurrent
        -- confirms cannot both win. Zero rows -> CATCH.
        UPDATE Lots.VendorReturn
        SET ConfirmedAt = SYSUTCDATETIME(), ConfirmedByUserId = @AppUserId
        WHERE Id = @VendorReturnId AND ConfirmedAt IS NULL AND CancelledAt IS NULL;

        IF @@ROWCOUNT = 0
            RAISERROR(N'The vendor return is no longer open (concurrent update). Reload and retry.', 16, 1);

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LotName + N' ' + Audit.ufn_MidDot() + N' Vendor return ' + Audit.ufn_MidDot()
            + N' Confirmed returned ' + CAST(@Qty AS NVARCHAR(20)) + N' pcs');
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT vr.Id AS VendorReturnId, vr.Quantity,
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
            @LogEventTypeCode   = N'VendorReturnConfirmed',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Vendor return confirmed.';
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
                @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnConfirmed',
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
