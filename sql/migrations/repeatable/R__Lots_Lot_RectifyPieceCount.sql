-- ============================================================
-- Repeatable:  R__Lots_Lot_RectifyPieceCount.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-25
-- Version:     1.2
-- Change:      v1.1 (2026-09-22) -- the mutation moved into
--              Lots.Lot_ApplyPieceCountCorrection (spec 2026-09-21 sec 5.1) so
--              a die cast shift reconciliation corrects a count the same way,
--              with the same LotAttributeChange trail. Every validation --
--              status, MaxLotSize, the no-op, availability -- stays here.
--              v1.2 (2026-09-25, code review) -- deleted the dead upper clamp on
--              @NewInvAvail (the worker recomputes availability under the row
--              lock; nothing here read the clamped value). The negative-
--              availability REJECTING GUARD above it is live and stays. Also
--              documented why @NewId is read back by max Id rather than
--              SCOPE_IDENTITY(), and the single-writer + row-lock invariant that
--              makes that read-back correct. No other behaviour change.
-- Description: Backlog 5.3. Operator-driven correction of a LOT's piece count
--              from the LOT Detail screen, with a MANDATORY reason.
--
--              WHY THIS MUTATES THE COUNT RATHER THAN WRITING A DERIVED-FROM
--              CORRECTION EVENT
--              --------------------------------------------------------------
--              The OI-35 architecture gate (decision B5) made Lots.Lot.PieceCount
--              / InventoryAvailable MATERIALIZED columns: every writer in the
--              system (Lot_Create, Lot_Split, RejectEvent_Record, TrimOut_Record,
--              MachiningOut_Mint, DieCastLot_Release) mutates them in place and
--              nothing re-derives them from an event stream. Introducing a
--              "correction event" that the count is computed from would put this
--              one proc at odds with all six of them and with every read that
--              trusts the column (queues, FIFO walks, availability guards).
--
--              History is preserved the way the model already preserves it:
--                * ONE append-only Lots.LotAttributeChange row carrying
--                  AttributeName='PieceCount', OldValue, NewValue AND the
--                  operator's Reason (0059). Lots.Lot_GetAttributeHistory
--                  surfaces it in the LOT timeline as an 'Attribute' event.
--                * ONE routed 'Lot'/'LotUpdated' audit operation, so the
--                  correction lands in the 20-year Lots.LotEventLog with
--                  resolved-FK Old/New JSON including the reason.
--              The count is therefore always explainable after the fact, without
--              breaking the materialized-quantity contract.
--
--              DIFFERENCES FROM Lots.Lot_UpdateAttribute (which stays as-is
--              because Lot_Split depends on its exact behaviour):
--                * @Reason is REQUIRED and non-blank (the whole point).
--                * InventoryAvailable is moved by the SAME DELTA as PieceCount
--                  (clamped to [0, @NewPieceCount]) instead of being ASSIGNED
--                  @NewPieceCount. Lot_UpdateAttribute's assignment is a Phase-2
--                  simplification from before consumption existed; on a partly
--                  consumed LOT it would hand back availability that has already
--                  been drawn.
--                * @NewPieceCount must be > 0. Rectification fixes a wrong count;
--                  taking a LOT to zero is a scrap (Workorder.RejectEvent_Record,
--                  which closes at zero) or a void, not a count correction.
--
--              FDS-11-011 + Msg-3915 rules: no OUTPUT params; @Status/@Message/
--              @NewId are locals; ALL rejecting validations run BEFORE BEGIN
--              TRANSACTION (this proc is captured via INSERT-EXEC by tests, so a
--              ROLLBACK inside an open caller transaction throws Msg 3915 --
--              CATCH is the only legal ROLLBACK site). The B2 not-blocked guard
--              is INLINED (mirror of Lots.Lot_AssertNotBlocked) rather than
--              EXEC'd, because EXEC of a sibling status-row proc would pollute
--              the single result set / nest INSERT-EXEC. RAISERROR (not THROW)
--              in the CATCH. Single terminal row: Status, Message, NewId (the
--              Lots.LotAttributeChange.Id).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_RectifyPieceCount
    @LotId              BIGINT,
    @NewPieceCount      INT,
    @Reason             NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_RectifyPieceCount';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @NewPieceCount AS NewPieceCount,
               LEFT(@Reason, 400) AS Reason, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName        NVARCHAR(50);
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;
    DECLARE @OldPieceCount  INT;
    DECLARE @OldInvAvail    INT;
    DECLARE @ItemId         BIGINT;
    DECLARE @MaxLotSize     INT;
    DECLARE @Delta          INT;
    DECLARE @NewInvAvail    INT;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @NewPieceCount IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, NewPieceCount, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. Reason is MANDATORY (backlog 5.3) ----
        SET @Reason = LTRIM(RTRIM(ISNULL(@Reason, N'')));
        IF @Reason = N''
        BEGIN
            SET @Message = N'A reason is required to rectify a LOT piece count.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. AppUser resolves ----
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. LOT exists (read name / status / quantities for the guards) ----
        SELECT @LotName       = l.LotName,
               @StatusCode    = sc.Code,
               @StatusName    = sc.Name,
               @Blocks        = sc.BlocksProduction,
               @OldPieceCount = l.PieceCount,
               @OldInvAvail   = l.InventoryAvailable,
               @ItemId        = l.ItemId
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. B2 not-blocked guard (INLINED mirror of Lots.Lot_AssertNotBlocked).
        --         Inlined, not EXEC'd: nesting INSERT-EXEC of the guard is illegal and
        --         its result set would pollute this proc's single terminal row. ----
        IF @Blocks = 1 OR @StatusCode IN (N'Closed', N'Open')
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode
                         + N') and cannot be rectified; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. New count sanity ----
        -- > 0 only: rectification corrects a mis-keyed count. Taking a LOT to zero is
        -- a scrap (Workorder.RejectEvent_Record closes the LOT at zero) or a void.
        IF @NewPieceCount <= 0
        BEGIN
            SET @Message = N'Corrected piece count must be greater than zero. To empty a LOT, scrap or void it instead.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @NewPieceCount = @OldPieceCount
        BEGIN
            SET @Message = N'Corrected piece count is the same as the current count ('
                         + CAST(@OldPieceCount AS NVARCHAR(20)) + N'); nothing to rectify.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @MaxLotSize = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
        IF @MaxLotSize IS NOT NULL AND @NewPieceCount > @MaxLotSize
        BEGIN
            SET @Message = N'Corrected piece count ' + CAST(@NewPieceCount AS NVARCHAR(20))
                         + N' exceeds Item MaxLotSize ' + CAST(@MaxLotSize AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Availability moves by the SAME delta as the count. A downward correction
        -- that would drive availability below zero means more pieces have already
        -- been consumed than the corrected count admits -- reject rather than
        -- silently floor, so the operator sees it. This is a REJECTING GUARD and it
        -- runs here, before BEGIN TRANSACTION, like every other one (Msg 3915).
        -- @NewInvAvail is used for THIS TEST ONLY. The value written is computed
        -- again inside Lots.Lot_ApplyPieceCountCorrection under the row lock, which
        -- is the only place it can be computed safely; v1.1 left an upper clamp here
        -- as well, which nothing downstream read.
        SET @Delta       = @NewPieceCount - @OldPieceCount;
        SET @NewInvAvail = @OldInvAvail + @Delta;
        IF @NewInvAvail < 0
        BEGIN
            SET @Message = N'Corrected piece count ' + CAST(@NewPieceCount AS NVARCHAR(20))
                         + N' is below the pieces already consumed from this LOT ('
                         + CAST(@OldPieceCount - @OldInvAvail AS NVARCHAR(20)) + N' of '
                         + CAST(@OldPieceCount AS NVARCHAR(20)) + N').';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        -- The write itself lives in Lots.Lot_ApplyPieceCountCorrection, a
        -- worker with no result set, no transaction and no TRY/CATCH, so this proc
        -- and Workorder.DieCastShiftReconciliation_Save correct a count the same
        -- way. It takes the Lot row under UPDLOCK/HOLDLOCK and re-checks the count
        -- under that lock: @OldPieceCount above was read UNLOCKED, before BEGIN
        -- TRANSACTION, so it is passed in as @ExpectedPieceCount. A mismatch (or
        -- availability going negative) RAISERRORs into this proc's CATCH.
        -- @OldValue / @NewValue stay here -- the success message below builds from
        -- them.
        DECLARE @OldValue NVARCHAR(500) = CAST(@OldPieceCount AS NVARCHAR(500));
        DECLARE @NewValue NVARCHAR(500) = CAST(@NewPieceCount AS NVARCHAR(500));

        BEGIN TRANSACTION;
        EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @LotId, @NewPieceCount = @NewPieceCount,
            @Reason = @Reason, @ExpectedPieceCount = @OldPieceCount,
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        -- @NewId is READ BACK by max Id, not taken from SCOPE_IDENTITY(), and that
        -- is forced, not sloppy: the INSERT happens inside
        -- Lots.Lot_ApplyPieceCountCorrection, and SCOPE_IDENTITY() is scoped to the
        -- calling MODULE -- across an EXEC it returns NULL. @@IDENTITY would cross
        -- the scope but reports the last identity from ANY scope, so a trigger on
        -- Lots.LotAttributeChange (or on Lots.Lot) would hand back the wrong row.
        --
        -- INVARIANT that makes this read-back correct: EVERY writer of a
        -- 'PieceCount' Lots.LotAttributeChange row goes through
        -- Lots.Lot_ApplyPieceCountCorrection, which takes the Lots.Lot row under
        -- (UPDLOCK, HOLDLOCK) BEFORE inserting. Two concurrent corrections of the
        -- same LOT therefore serialize, and the newest row inside this transaction
        -- is this transaction's. ADD A SECOND WRITER THAT DOES NOT TAKE THAT LOCK
        -- AND THIS RETURNS ANOTHER SESSION'S Id.
        SET @NewId = (SELECT TOP 1 Id FROM Lots.LotAttributeChange
                      WHERE LotId = @LotId AND AttributeName = N'PieceCount' ORDER BY Id DESC);
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @LotName + N' piece count corrected '
                     + @OldValue + N' to ' + @NewValue + N'.';
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
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
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
