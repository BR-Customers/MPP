-- ============================================================
-- Repeatable:  R__Workorder_RejectEvent_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.1
-- Change Log:  2026-06-16 - 1.1 - TOCTOU guard: re-check the decremented PieceCount
--                                 under UPDLOCK; RAISERROR on negative (concurrent
--                                 over-reject) routes to CATCH = clean Status 0.
-- Description: Arc 2 Phase 3 (§4.2 + D3). Records ONE reject/scrap event against
--              a LOT (Workorder.RejectEvent) and, per D3, decrements the LOT's
--              materialized B5 quantities (Lot.PieceCount + Lot.InventoryAvailable)
--              by @Quantity. When the decrement drives the LOT to zero pieces, the
--              LOT is CLOSED in the same transaction (the close-at-zero block is an
--              INLINED mirror of Lots.Lot_UpdateStatus' Good->Closed path).
--
--              D3 details:
--                * Lot.PieceCount         -= @Quantity   (cannot go below zero)
--                * Lot.InventoryAvailable -= @Quantity   (floored at zero)
--                * PieceCount reaching 0  -> LotStatusCode 'Closed' + a
--                  LotStatusHistory row (Old=Good, New=Closed) + a routed
--                  'Lot'/'LotStatusChanged' audit op (so the close lands in the
--                  20-yr LotEventLog like any other LOT status change).
--
--              @TerminalLocationId is AUDIT-ONLY: Workorder.RejectEvent has NO
--              TerminalLocationId column (verified against 0020). It is passed to
--              the audit writers (and the inlined close's LotStatusHistory) but is
--              NOT inserted into RejectEvent.
--
--              FDS-11-011 + Msg-3915 rules: ALL rejecting validations run BEFORE
--              BEGIN TRANSACTION (this proc is captured via INSERT-EXEC, so a
--              ROLLBACK in an open caller txn throws Msg 3915 — CATCH is the only
--              legal ROLLBACK site). The held-LOT guard is INLINED (mirror of
--              Lots.Lot_AssertNotBlocked); the close-at-zero status change is
--              INLINED (mirror of Lots.Lot_UpdateStatus) rather than EXEC'd,
--              because EXEC of a sibling status-row proc would pollute the single
--              result set / nest INSERT-EXEC. The Lot row is taken under
--              UPDLOCK/HOLDLOCK while PieceCount is mutated (mirrors Lot_Split).
--              Single terminal row: Status, Message, NewId. @Status BIT.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.RejectEvent_Record
    @LotId               BIGINT,
    @DefectCodeId        BIGINT,
    @Quantity            INT,
    @ProductionEventId   BIGINT         = NULL,
    @ChargeToArea        NVARCHAR(100)  = NULL,
    @Remarks             NVARCHAR(500)  = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT         = NULL   -- audit-only; no column on RejectEvent
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.RejectEvent_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @DefectCodeId AS DefectCodeId, @Quantity AS Quantity,
               @ProductionEventId AS ProductionEventId, @ChargeToArea AS ChargeToArea,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @StatusCode NVARCHAR(20);
    DECLARE @StatusName NVARCHAR(100);
    DECLARE @Blocks     BIT;
    DECLARE @CurrentStatusId BIGINT;
    DECLARE @PieceCount      INT;
    DECLARE @InventoryAvail  INT;

    DECLARE @GoodStatusId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @DefectCodeId IS NULL OR @Quantity IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, DefectCodeId, Quantity, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                    @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. Quantity sanity ----
        IF @Quantity <= 0
        BEGIN
            SET @Message = N'Quantity must be greater than zero.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. FK resolution ----
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Id = @DefectCodeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'DefectCode not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ProductionEventId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Workorder.ProductionEvent WHERE Id = @ProductionEventId)
        BEGIN
            SET @Message = N'ProductionEvent not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. LOT existence + held-LOT guard (INLINED mirror of Lots.Lot_AssertNotBlocked) ----
        SELECT @CurrentStatusId = l.LotStatusId,
               @StatusCode      = sc.Code,
               @StatusName      = sc.Name,
               @Blocks          = sc.BlocksProduction,
               @PieceCount      = l.PieceCount,
               @InventoryAvail  = l.InventoryAvailable
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Blocked: Hold/Scrap (BlocksProduction) or terminal Closed cannot reject.
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot record a reject.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Quantity cannot exceed remaining pieces (D3 cannot go below zero) ----
        IF @Quantity > @PieceCount
        BEGIN
            SET @Message = N'Reject Quantity ' + CAST(@Quantity AS NVARCHAR(20))
                         + N' exceeds LOT remaining pieces ' + CAST(@PieceCount AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- Insert the reject record. NOTE: @TerminalLocationId is NOT a column on
        -- RejectEvent (audit-only) — it is deliberately omitted here.
        INSERT INTO Workorder.RejectEvent (
            ProductionEventId, LotId, DefectCodeId, Quantity,
            ChargeToArea, Remarks, AppUserId, RecordedAt
        )
        VALUES (
            @ProductionEventId, @LotId, @DefectCodeId, @Quantity,
            @ChargeToArea, @Remarks, @AppUserId, SYSUTCDATETIME()
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- D3: decrement materialized B5 quantities under UPDLOCK/HOLDLOCK on the
        -- Lot row (mirrors the Lot_Split PieceCount-mutation locking). PieceCount
        -- is bounded >= 0 by the validation above; InventoryAvailable is floored
        -- at 0 defensively (it can already trail PieceCount via consumption).
        DECLARE @NewPieceCount     INT;
        DECLARE @NewInventoryAvail INT;

        UPDATE l
        SET @NewPieceCount     = l.PieceCount - @Quantity,
            @NewInventoryAvail = CASE WHEN l.InventoryAvailable - @Quantity < 0 THEN 0
                                      ELSE l.InventoryAvailable - @Quantity END,
            l.PieceCount        = l.PieceCount - @Quantity,
            l.InventoryAvailable= CASE WHEN l.InventoryAvailable - @Quantity < 0 THEN 0
                                       ELSE l.InventoryAvailable - @Quantity END,
            l.UpdatedAt         = SYSUTCDATETIME(),
            l.UpdatedByUserId   = @AppUserId
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.Id = @LotId;

        -- Concurrency guard (TOCTOU): the @Quantity > @PieceCount gate above read
        -- PieceCount UNLOCKED, before BEGIN TRANSACTION. Re-check against the value
        -- read under UPDLOCK; a concurrent reject that slipped between the gate and
        -- this lock would drive PieceCount negative (and skip close-at-zero, since
        -- @NewPieceCount would be < 0, not = 0). RAISERROR lands in the CATCH (the
        -- only legal ROLLBACK site under INSERT-EXEC / Msg-3915) -> clean Status=0.
        IF @NewPieceCount < 0
            RAISERROR(N'Reject Quantity exceeds the LOT''s remaining pieces (concurrent update). Reload and retry.', 16, 1);

        -- ----- Reject audit (resolved-FK JSON + readable Description) -----
        DECLARE @LotName    NVARCHAR(50)  = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @DefCode    NVARCHAR(50)  = (SELECT Code FROM Quality.DefectCode WHERE Id = @DefectCodeId);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Reject ' + Audit.ufn_MidDot()
            + N' ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs (' + ISNULL(@DefCode, N'?') + N')'
            + N'; remaining ' + CAST(@NewPieceCount AS NVARCHAR(20));
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                re.Id, re.Quantity,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = re.LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                JSON_QUERY((SELECT dc.Id, dc.Code, dc.Description AS Name
                            FROM Quality.DefectCode dc WHERE dc.Id = re.DefectCodeId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DefectCode
            FROM Workorder.RejectEvent re WHERE re.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'RejectEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'RejectEventRecorded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        -- ===== D3 close-at-zero (INLINED mirror of Lots.Lot_UpdateStatus Good->Closed) =====
        -- When the reject drives the LOT to zero pieces, close it in the same txn.
        -- Mirror block: set LotStatusId=Closed, write a LotStatusHistory row, and
        -- emit a routed 'Lot'/'LotStatusChanged' audit op (so the close lands in
        -- the 20-yr Lots.LotEventLog, exactly as Lot_UpdateStatus would). Inlined
        -- (not EXEC Lots.Lot_UpdateStatus) per the INSERT-EXEC / single-result-set
        -- rule. Source of truth: R__Lots_Lot_UpdateStatus.sql.
        IF @NewPieceCount = 0 AND @CurrentStatusId = @GoodStatusId
        BEGIN
            UPDATE Lots.Lot
            SET LotStatusId     = @ClosedStatusId,
                UpdatedAt       = SYSUTCDATETIME(),
                UpdatedByUserId = @AppUserId
            WHERE Id = @LotId;

            INSERT INTO Lots.LotStatusHistory
                (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES
                (@LotId, @CurrentStatusId, @ClosedStatusId,
                 N'Closed automatically: all pieces rejected.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            DECLARE @CloseOld NVARCHAR(MAX) = (
                SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @CurrentStatusId
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            DECLARE @CloseNew NVARCHAR(MAX) = (
                SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            DECLARE @CloseRaw NVARCHAR(MAX) =
                @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
                + N' Good' + NCHAR(8594) + N'Closed (all pieces rejected)';
            DECLARE @CloseActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(@CloseRaw);

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
        SET @Message = CASE WHEN @NewPieceCount = 0
                            THEN N'Reject recorded; LOT closed (zero pieces remaining).'
                            ELSE N'Reject recorded; ' + CAST(@NewPieceCount AS NVARCHAR(20)) + N' pieces remaining.' END;
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'RejectEventRecorded',
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
