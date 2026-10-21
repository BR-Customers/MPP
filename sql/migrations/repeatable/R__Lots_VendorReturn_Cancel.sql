-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_Cancel.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.2
-- Modified:    2026-10-21
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
--              Super-lot side (spec 5.4): when the return is linked to a
--              Quality.ControlledRunResult (ControlledRunResultId), that entry is
--              voided in the same transaction (VoidedAt, VoidedByUserId,
--              VoidRemarks = @CancelRemarks) -- an applied return result cannot be
--              voided any other way.
--              Single terminal row: Status, Message.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
--   2026-10-19 - 1.1 - Voids the linked super-lot result (piece 5). The Closed / Scrap /
--                      Open LOT guard is repeated on the locked UPDATE (Task 6 review).
--   2026-10-21 - 1.2 - Super-lot piece 6: the void is also written onto the member's
--                      LOT ('Result voided . Return to Supplier <qty> (<cancel remarks>)',
--                      ControlledRunLotResultVoided), as ControlledRunResult_Void v1.2 does.
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
    DECLARE @ResultId BIGINT, @RunId BIGINT, @RunNumber NVARCHAR(15);

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
               @StatusCode = sc.Code, @StatusName = sc.Name,
               @ResultId = vr.ControlledRunResultId, @RunId = r.Id, @RunNumber = r.RunNumber
        FROM Lots.VendorReturn vr
        INNER JOIN Lots.Lot l ON l.Id = vr.LotId
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        LEFT JOIN Quality.ControlledRunResult rr ON rr.Id = vr.ControlledRunResultId
        LEFT JOIN Quality.ControlledRunMember m  ON m.Id = rr.ControlledRunMemberId
        LEFT JOIN Quality.ControlledRun r        ON r.Id = m.ControlledRunId
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
        -- sees @@ROWCOUNT = 1. The LOT status guard is repeated here, under the
        -- lock: the check above was read unlocked.
        DECLARE @NewPieceCount INT;
        UPDATE l
        SET @NewPieceCount       = l.PieceCount + @PcTaken,
            l.PieceCount         = l.PieceCount + @PcTaken,
            l.InventoryAvailable = l.InventoryAvailable + @InvTaken,
            l.UpdatedAt          = SYSUTCDATETIME(),
            l.UpdatedByUserId    = @AppUserId
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.Id = @LotId
          AND l.LotStatusId NOT IN (SELECT sc.Id FROM Lots.LotStatusCode sc WHERE sc.Code IN (N'Closed', N'Scrap', N'Open'))
          AND EXISTS (SELECT 1 FROM Lots.VendorReturn vr
                      WHERE vr.Id = @VendorReturnId AND vr.ConfirmedAt IS NULL AND vr.CancelledAt IS NULL);

        IF @@ROWCOUNT = 0
            RAISERROR(N'The vendor return is no longer open, or the LOT can no longer take the pieces back (concurrent update). Reload and retry.', 16, 1);

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

        -- Super-lot side: the linked ReturnToSupplier entry stops counting with the
        -- return. Same stamp as Quality.ControlledRunResult_Void (mirror of its UPDATE,
        -- its run-level audit row and, v1.2, its per-LOT 'Result voided' row); voided
        -- whether or not the super-lot is still open, because the pieces it explained
        -- are back on the LOT.
        IF @ResultId IS NOT NULL
        BEGIN
            UPDATE Quality.ControlledRunResult
            SET VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @AppUserId, VoidRemarks = @CancelRemarks
            WHERE Id = @ResultId AND VoidedAt IS NULL;

            IF @@ROWCOUNT = 1
            BEGIN
                DECLARE @RunActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(
                    @RunNumber + N' ' + Audit.ufn_MidDot() + N' Results ' + Audit.ufn_MidDot()
                    + N' - ' + @LotName + N' Return to Supplier ' + CAST(@Qty AS NVARCHAR(20))
                    + N' voided (vendor return cancelled): ' + @CancelRemarks);
                DECLARE @RunNewValue NVARCHAR(MAX) = (
                    SELECT @ResultId AS ResultId, @VendorReturnId AS VendorReturnId, @LotName AS Member,
                           N'ReturnToSupplier' AS Outcome, @Qty AS Quantity, @CancelRemarks AS VoidRemarks,
                           JSON_QUERY((SELECT @RunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                EXEC Audit.Audit_LogOperation
                    @AppUserId          = @AppUserId,
                    @TerminalLocationId = @TerminalLocationId,
                    @LocationId         = NULL,
                    @LogEntityTypeCode  = N'ControlledRun',
                    @EntityId           = @RunId,
                    @LogEventTypeCode   = N'ControlledRunResultVoided',
                    @LogSeverityCode    = N'Info',
                    @Description        = @RunActivity,
                    @OldValue           = NULL,
                    @NewValue           = @RunNewValue;

                -- v1.2: the void on the member's own LOT timeline (mirror of
                -- ControlledRunResult_Void v1.2's per-LOT row)
                DECLARE @VoidMemberJson NVARCHAR(MAX), @VoidText NVARCHAR(400);
                SELECT @VoidMemberJson = N'[' + CAST(rr.ControlledRunMemberId AS NVARCHAR(20)) + N']',
                       @VoidText = LEFT(N'Result voided ' + Audit.ufn_MidDot() + N' ' + dc.Name + N' '
                                        + CAST(rr.Quantity AS NVARCHAR(10)) + N' (' + @CancelRemarks + N')', 400)
                FROM Quality.ControlledRunResult rr
                INNER JOIN Quality.DispositionCode dc ON dc.Id = rr.DispositionCodeId
                WHERE rr.Id = @ResultId;
                EXEC Quality.ControlledRun_LogMemberLotEventsInternal
                    @MemberIdsJson = @VoidMemberJson, @LogEventTypeCode = N'ControlledRunLotResultVoided',
                    @ActionText = @VoidText, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
            END
        END

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
