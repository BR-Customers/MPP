-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_Mark.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.3
-- Description: Super-lot piece 5 (spec 5.1). Marks part of a purchased /
--              received LOT for return to the vendor: the quantity leaves the
--              LOT NOW (PieceCount and InventoryAvailable together) and a
--              Lots.VendorReturn row records exactly what was taken so Cancel
--              can restore it. Confirm later stamps it as shipped back.
--
--              Only Received / ReceivedOffsite origin LOTs may be returned.
--              Hold LOTs are allowed (a held box is a prime return candidate);
--              Open / Scrap / Closed are refused. That rule and its refusal text
--              are Lots.ufn_LotReturnableToVendor -- the one definition, shared
--              with ControlledRunResult_Record, ControlledRun_ListMemberOrigin and
--              VendorReturn_GetEligibility (LOT Detail).
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
--              Super-lot side (spec 5.4): when the LOT is a CURRENT member of an
--              OPEN super-lot, the same transaction writes an applied
--              ReturnToSupplier Quality.ControlledRunResult (RecordedByUserId =
--              the marker, Remarks = @Remarks) and the VendorReturn points at it,
--              so the super-lot's left-over stays explained. A LOT whose
--              membership has ended, or whose super-lot is not open, gets no
--              result; the return itself still succeeds.
--
--              FDS-11-011 / Msg-3915: all rejecting validations run before
--              BEGIN TRANSACTION; CATCH is the only ROLLBACK site.
--              Single terminal row: Status, Message, NewId.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
--   2026-10-19 - 1.1 - Writes an applied ReturnToSupplier result for a current member
--                      of an open super-lot, linked by ControlledRunResultId (piece 5).
--   2026-10-20 - 1.2 - Final review: origin + status rule read from Lots.ufn_LotReturnableToVendor
--                      (same refusal text). The LOT status is re-checked under the
--                      UPDLOCK/HOLDLOCK (the locked UPDATE matches only the status read
--                      before the transaction), routed to CATCH like the quantity re-check,
--                      so a concurrent Good->Hold cannot be closed from the wrong status.
--   2026-10-21 - 1.3 - Piece 6 final review: the applied ReturnToSupplier result for a
--                      current member also writes the member LOT's 'Result recorded'
--                      row (ControlledRunLotResult via ControlledRun_LogMemberLotEventsInternal),
--                      as ControlledRunResult_Record v1.4 does, so Cancel's 'Result voided'
--                      row has its pair.
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
    DECLARE @CurrentStatusId BIGINT;
    DECLARE @PieceCount      INT;
    DECLARE @InventoryAvail  INT;
    DECLARE @GoodStatusId    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId  BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
    DECLARE @ReturnDispId    BIGINT = (SELECT Id FROM Quality.DispositionCode WHERE Code = N'ReturnToSupplier');
    DECLARE @MemberId        BIGINT = NULL;
    DECLARE @RunId           BIGINT = NULL;
    DECLARE @RunNumber       NVARCHAR(15) = NULL;
    DECLARE @ResultId        BIGINT = NULL;

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
               @PieceCount      = l.PieceCount,
               @InventoryAvail  = l.InventoryAvailable
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        -- Origin + status: the shared rule (Lots.ufn_LotReturnableToVendor). Its Reason
        -- is the refusal text, origin first, then status.
        DECLARE @Returnable BIT;
        DECLARE @NotReturnableReason NVARCHAR(500);
        SELECT @Returnable = rv.CanReturnToVendor, @NotReturnableReason = rv.Reason
        FROM Lots.ufn_LotReturnableToVendor(@LotId) rv;

        IF (@StatusCode IS NULL)
            SET @Message = N'LOT not found.';
        ELSE IF (@Returnable = 0)
            SET @Message = @NotReturnableReason;
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
        -- The LOT status is re-checked here, under the lock: the locked UPDATE
        -- matches only while the status is still the one validated above.
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
        WHERE l.Id = @LotId
          AND l.LotStatusId = @CurrentStatusId;

        -- TOCTOU re-checks under the lock -> CATCH (only legal ROLLBACK site).
        IF @@ROWCOUNT = 0
            RAISERROR(N'The LOT''s status changed while the return was being marked (concurrent update). Reload and retry.', 16, 1);
        IF @NewPieceCount < 0
            RAISERROR(N'Return quantity exceeds the LOT''s remaining pieces (concurrent update). Reload and retry.', 16, 1);

        -- Super-lot side (spec 5.4). INLINED form of the query in
        -- Quality.ControlledRun_GetOpenByMember (a read proc, never EXEC'd from a
        -- mutation), narrowed to a LOT member and to an OPEN run -- the same lookup
        -- Lots.ContainerRework_Scrap inlines for a container. A received LOT is never
        -- a tray LOT, so GetOpenByMember's tray -> container step does not apply.
        -- Read after the Lot lock, inside the transaction.
        SELECT TOP 1 @MemberId = m.Id, @RunId = r.Id, @RunNumber = r.RunNumber
        FROM Quality.ControlledRunMember m
        INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
        WHERE (m.LotId = @LotId) AND (m.EndedAt IS NULL) AND (r.ControlledRunStatusId = 1);

        -- The result row first: Lots.VendorReturn.ControlledRunResultId is an FK to it.
        IF @MemberId IS NOT NULL
        BEGIN
            INSERT INTO Quality.ControlledRunResult
                (ControlledRunMemberId, DispositionCodeId, Quantity, DefectCodeId, RejectEventId, Remarks,
                 RecordedByUserId, TerminalLocationId)
            VALUES
                (@MemberId, @ReturnDispId, @Quantity, NULL, NULL, @Remarks,
                 @AppUserId, @TerminalLocationId);
            SET @ResultId = CAST(SCOPE_IDENTITY() AS BIGINT);
        END

        INSERT INTO Lots.VendorReturn
            (LotId, Quantity, PieceCountTaken, InventoryTaken, Remarks, ControlledRunResultId,
             MarkedByUserId, MarkedAt, TerminalLocationId)
        VALUES
            (@LotId, @Quantity, @Quantity, @InvTaken, @Remarks, @ResultId,
             @AppUserId, SYSUTCDATETIME(), @TerminalLocationId);
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Vendor return ' + Audit.ufn_MidDot()
            + N' Marked ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs; remaining ' + CAST(@NewPieceCount AS NVARCHAR(20))
            + CASE WHEN @RunNumber IS NOT NULL THEN N' (super-lot ' + @RunNumber + N')' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT vr.Id AS VendorReturnId, vr.Quantity, vr.PieceCountTaken, vr.InventoryTaken, vr.Remarks,
                   vr.ControlledRunResultId,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                               FROM Lots.Lot l WHERE l.Id = vr.LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT @RunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                               WHERE @RunId IS NOT NULL
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
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

        -- The super-lot's own history shows the entry (as ControlledRunResult_Record's
        -- ControlledRunResultRecorded row does).
        IF @ResultId IS NOT NULL
        BEGIN
            DECLARE @RunActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(
                @RunNumber + N' ' + Audit.ufn_MidDot() + N' Results ' + Audit.ufn_MidDot()
                + N' + ' + @LotName + N' Return to Supplier ' + CAST(@Quantity AS NVARCHAR(20)) + N' (vendor return marked)');
            DECLARE @RunNewValue NVARCHAR(MAX) = (
                SELECT @ResultId AS ResultId, @NewId AS VendorReturnId, @LotName AS Member,
                       N'ReturnToSupplier' AS Outcome, @Quantity AS Quantity,
                       JSON_QUERY((SELECT @RunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC Audit.Audit_LogOperation
                @AppUserId          = @AppUserId,
                @TerminalLocationId = @TerminalLocationId,
                @LocationId         = NULL,
                @LogEntityTypeCode  = N'ControlledRun',
                @EntityId           = @RunId,
                @LogEventTypeCode   = N'ControlledRunResultRecorded',
                @LogSeverityCode    = N'Info',
                @Description        = @RunActivity,
                @OldValue           = NULL,
                @NewValue           = @RunNewValue;

            -- v1.3: the entry on the member's own LOT timeline, the same
            -- 'Result recorded . <outcome> <qty>' row ControlledRunResult_Record v1.4
            -- writes (silent helper, inside this transaction).
            DECLARE @ResultMemberJson NVARCHAR(MAX) = N'[' + CAST(@MemberId AS NVARCHAR(20)) + N']';
            DECLARE @ResultText NVARCHAR(400) = (
                SELECT LEFT(N'Result recorded ' + Audit.ufn_MidDot() + N' ' + dc.Name + N' '
                            + CAST(@Quantity AS NVARCHAR(10)), 400)
                FROM Quality.DispositionCode dc WHERE dc.Id = @ReturnDispId);
            EXEC Quality.ControlledRun_LogMemberLotEventsInternal
                @MemberIdsJson = @ResultMemberJson, @LogEventTypeCode = N'ControlledRunLotResult',
                @ActionText = @ResultText, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

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
