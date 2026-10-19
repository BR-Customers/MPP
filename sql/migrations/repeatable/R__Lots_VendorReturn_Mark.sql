-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_Mark.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5 (spec 5.1). Marks part of a purchased /
--              received LOT for return to the vendor: the quantity leaves the
--              LOT NOW (PieceCount and InventoryAvailable together) and a
--              Lots.VendorReturn row records exactly what was taken so Cancel
--              can restore it. Confirm later stamps it as shipped back.
--
--              Only Received / ReceivedOffsite origin LOTs may be returned.
--              Hold LOTs are allowed (a held box is a prime return candidate);
--              Open / Scrap / Closed are refused.
--
--              InventoryAvailable may be lower than PieceCount (it is drawn
--              down by consumption). When @Quantity exceeds it, it is floored
--              at zero and InventoryTaken records what was actually removed
--              (= the old InventoryAvailable), so Cancel restores exactly.
--
--              The decrement + close-at-zero is an INLINED mirror of
--              Workorder.RejectEvent_Record v2.0's subtractive path (UPDLOCK,
--              HOLDLOCK, in-transaction TOCTOU re-check routed to CATCH; Good
--              LOT closes at zero with a LotStatusHistory row, Hold stays
--              Hold). No RejectEvent is written -- a return is not scrap.
--
--              FDS-11-011 / Msg-3915: all rejecting validations run before
--              BEGIN TRANSACTION; CATCH is the only ROLLBACK site.
--              Single terminal row: Status, Message, NewId.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.VendorReturn_Mark
    @LotId              BIGINT,
    @Quantity           INT,
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.VendorReturn_Mark';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @Quantity AS Quantity, @Remarks AS Remarks,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName         NVARCHAR(50);
    DECLARE @StatusCode      NVARCHAR(20);
    DECLARE @StatusName      NVARCHAR(100);
    DECLARE @OriginCode      NVARCHAR(50);
    DECLARE @CurrentStatusId BIGINT;
    DECLARE @PieceCount      INT;
    DECLARE @InventoryAvail  INT;
    DECLARE @GoodStatusId    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId  BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF (@LotId IS NULL) OR (@Quantity IS NULL) OR (@AppUserId IS NULL)
        BEGIN
            SET @Message = N'Required parameter missing (LotId, Quantity, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnMarked',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. Quantity sanity ----
        IF (@Quantity <= 0)
        BEGIN
            SET @Message = N'Quantity must be greater than zero.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnMarked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. LOT existence, origin, status, quantity (first failing rule wins) ----
        SELECT @LotName         = l.LotName,
               @CurrentStatusId = l.LotStatusId,
               @StatusCode      = sc.Code,
               @StatusName      = sc.Name,
               @OriginCode      = ot.Code,
               @PieceCount      = l.PieceCount,
               @InventoryAvail  = l.InventoryAvailable
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        INNER JOIN Lots.LotOriginType ot ON ot.Id = l.LotOriginTypeId
        WHERE l.Id = @LotId;

        IF (@StatusCode IS NULL)
            SET @Message = N'LOT not found.';
        ELSE IF (@OriginCode NOT IN (N'Received', N'ReceivedOffsite'))
            SET @Message = N'LOT ' + @LotName + N' was made at MPP; only purchased or received material can be returned to a vendor.';
        ELSE IF (@StatusCode IN (N'Closed', N'Scrap', N'Open'))
            SET @Message = N'LOT ' + @LotName + N' is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot be returned to a vendor.';
        ELSE IF (@Quantity > @PieceCount)
            SET @Message = N'Return quantity ' + CAST(@Quantity AS NVARCHAR(20))
                         + N' exceeds LOT remaining pieces ' + CAST(@PieceCount AS NVARCHAR(20)) + N'.';
        ELSE
            SET @Message = NULL;

        IF @Message IS NOT NULL
        BEGIN
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnMarked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- INLINED mirror of Workorder.RejectEvent_Record v2.0 subtractive path
        -- (source: R__Workorder_RejectEvent_Record.sql). UPDLOCK/HOLDLOCK; the
        -- variables capture what was really taken and the new PieceCount.
        DECLARE @NewPieceCount INT;
        DECLARE @InvTaken      INT;
        UPDATE l
        SET @NewPieceCount       = l.PieceCount - @Quantity,
            @InvTaken            = CASE WHEN l.InventoryAvailable < @Quantity THEN l.InventoryAvailable ELSE @Quantity END,
            l.PieceCount         = l.PieceCount - @Quantity,
            l.InventoryAvailable = CASE WHEN l.InventoryAvailable - @Quantity < 0 THEN 0
                                        ELSE l.InventoryAvailable - @Quantity END,
            l.UpdatedAt          = SYSUTCDATETIME(),
            l.UpdatedByUserId    = @AppUserId
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.Id = @LotId;

        -- TOCTOU re-check under the lock -> CATCH (only legal ROLLBACK site).
        IF @NewPieceCount < 0
            RAISERROR(N'Return quantity exceeds the LOT''s remaining pieces (concurrent update). Reload and retry.', 16, 1);

        INSERT INTO Lots.VendorReturn
            (LotId, Quantity, PieceCountTaken, InventoryTaken, Remarks,
             MarkedByUserId, MarkedAt, TerminalLocationId)
        VALUES
            (@LotId, @Quantity, @Quantity, @InvTaken, @Remarks,
             @AppUserId, SYSUTCDATETIME(), @TerminalLocationId);
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Vendor return ' + Audit.ufn_MidDot()
            + N' Marked ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs; remaining ' + CAST(@NewPieceCount AS NVARCHAR(20));
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT vr.Id AS VendorReturnId, vr.Quantity, vr.PieceCountTaken, vr.InventoryTaken, vr.Remarks,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                               FROM Lots.Lot l WHERE l.Id = vr.LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot
            FROM Lots.VendorReturn vr WHERE vr.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'VendorReturnMarked',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        -- Close-at-zero: INLINED mirror of Lots.Lot_UpdateStatus Good->Closed
        -- (as in RejectEvent_Record). Hold stays Hold.
        IF @NewPieceCount = 0 AND @CurrentStatusId = @GoodStatusId
        BEGIN
            UPDATE Lots.Lot
            SET LotStatusId = @ClosedStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @LotId;

            INSERT INTO Lots.LotStatusHistory
                (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES
                (@LotId, @CurrentStatusId, @ClosedStatusId,
                 N'Closed automatically: all pieces returned to the vendor.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            DECLARE @CloseOld NVARCHAR(MAX) = (
                SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @CurrentStatusId
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            DECLARE @CloseNew NVARCHAR(MAX) = (
                SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            DECLARE @CloseActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(
                @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
                + N' Good' + NCHAR(8594) + N'Closed (all pieces returned to vendor)');

            EXEC Audit.Audit_LogOperation
                @AppUserId          = @AppUserId,
                @TerminalLocationId = @TerminalLocationId,
                @LocationId         = NULL,
                @LogEntityTypeCode  = N'Lot',
                @EntityId           = @LotId,
                @LogEventTypeCode   = N'LotStatusChanged',
                @LogSeverityCode    = N'Info',
                @Description        = @CloseActivity,
                @OldValue           = @CloseOld,
                @NewValue           = @CloseNew;
        END

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CASE WHEN @NewPieceCount = 0 AND @CurrentStatusId = @GoodStatusId
                            THEN N'Marked for return; LOT closed (zero pieces remaining).'
                            WHEN @NewPieceCount = 0
                            THEN N'Marked for return; 0 pieces remaining; LOT remains on hold.'
                            ELSE N'Marked for return; ' + CAST(@NewPieceCount AS NVARCHAR(20)) + N' pieces remaining.' END;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'VendorReturnMarked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
