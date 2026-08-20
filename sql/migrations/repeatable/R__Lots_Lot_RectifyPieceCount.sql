-- ============================================================
-- Repeatable:  R__Lots_Lot_RectifyPieceCount.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     1.0
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
        IF @Blocks = 1 OR @StatusCode = N'Closed'
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

        -- Availability moves by the SAME delta as the count, clamped to
        -- [0, @NewPieceCount]. A downward correction that would drive availability
        -- below zero means more pieces have already been consumed than the corrected
        -- count admits -- reject rather than silently floor, so the operator sees it.
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
        IF @NewInvAvail > @NewPieceCount SET @NewInvAvail = @NewPieceCount;

        -- ===== Mutation (atomic) =====
        DECLARE @OldValue NVARCHAR(500) = CAST(@OldPieceCount AS NVARCHAR(500));
        DECLARE @NewValue NVARCHAR(500) = CAST(@NewPieceCount AS NVARCHAR(500));

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Rectify ' + Audit.ufn_MidDot()
            + N' PieceCount ' + @OldValue + NCHAR(8594) + @NewValue
            + N' (' + @Reason + N')';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        INSERT INTO Lots.LotAttributeChange
            (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES
            (@LotId, N'PieceCount', @OldValue, @NewValue, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Take the Lot row under UPDLOCK/HOLDLOCK while the materialized B5 quantities
        -- are mutated (mirrors Lot_Split / RejectEvent_Record). The concurrency guard
        -- below re-checks under the lock: the availability arithmetic above read
        -- InventoryAvailable UNLOCKED, before BEGIN TRANSACTION.
        DECLARE @LockedInvAvail INT, @LockedPieceCount INT;
        SELECT @LockedInvAvail = l.InventoryAvailable, @LockedPieceCount = l.PieceCount
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id = @LotId;

        IF @LockedPieceCount <> @OldPieceCount
            RAISERROR(N'The LOT piece count changed while the correction was being entered. Reload and retry.', 16, 1);

        SET @NewInvAvail = @LockedInvAvail + @Delta;
        IF @NewInvAvail < 0
            RAISERROR(N'The corrected piece count is below the pieces already consumed (concurrent update). Reload and retry.', 16, 1);
        IF @NewInvAvail > @NewPieceCount SET @NewInvAvail = @NewPieceCount;

        UPDATE Lots.Lot
        SET PieceCount         = @NewPieceCount,
            InventoryAvailable = @NewInvAvail,
            UpdatedAt          = SYSUTCDATETIME(),
            UpdatedByUserId    = @AppUserId
        WHERE Id = @LotId;

        DECLARE @OldJson NVARCHAR(MAX) = (
            SELECT N'PieceCount' AS Attribute, @OldPieceCount AS Value,
                   @OldInvAvail AS InventoryAvailable
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @NewJson NVARCHAR(MAX) = (
            SELECT N'PieceCount' AS Attribute, @NewPieceCount AS Value,
                   @NewInvAvail AS InventoryAvailable, @Reason AS Reason,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                               FROM Lots.Lot l WHERE l.Id = @LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                               FROM Location.Location loc
                               INNER JOIN Lots.Lot l2 ON l2.CurrentLocationId = loc.Id
                               WHERE l2.Id = @LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'LotUpdated',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldJson,
            @NewValue           = @NewJson;

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
