-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Release.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-15
-- Version:     2.2
-- Change:      v2.2 -- the CLOSING SCRAP rows now stamp their own identity
--              (ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
--              TerminalLocationId), finishing what v2.1 started. v2.1 taught
--              the CONTRIBUTION row to carry its cavity; the RejectEvent
--              insert a few lines below it kept the pre-0084 column list and
--              wrote NULL for all five. Consequence was invisible at the write
--              and total at the read: DieCast_GetShiftOutputBreakdown scopes
--              PriorScrapThisShift by ShiftId + ToolCavityId, so Reconcile
--              Shift's SHIFT SCRAP column reported 0 for scrap that was
--              genuinely recorded and NO amount of Compute or Refresh would
--              ever change it. Quality.Reject_GetPartMatrix / _SearchDetail
--              read re.ItemId, so the same rows also bucketed as an unmapped
--              part. Live evidence (Dev, 2026-09-15): reject 20054 (lot 20265,
--              qty 10) beside contribution 20102 (cavity 30, shift 20107) ->
--              column reported 0. Guarded by Tests 6-7 in
--              sql/tests/0022_PlantFloor_DieCast/090_ReleasePreview.sql.
--              NOTE for anyone backfilling: rows already written by <= v2.1
--              stay NULL-stamped and remain invisible to those reads.
--
--              v2.1 -- companion fix for Workorder.ufn_CavityShotWatermark
--              v3.0 (die-cast quantity + scrap model, spec sec 5.3b), which
--              reads DieCastContribution.ToolCavityId directly instead of
--              deriving the cavity via INNER JOIN Lots.Lot. That is only
--              behaviour-preserving if EVERY contribution row still carries
--              its cavity -- so the final-delta row written here now stamps
--              ToolCavityId from the already-resolved @RelToolCavityId (no
--              new lookup; this proc already reads it at line ~144 to derive
--              the delta). Without this, a basket released here would leave
--              its contribution row's cavity unresolvable under v3.0 and the
--              next basket on the same cavity would be credited from a stale
--              (zero) watermark -- exactly the regression Task 2's neutrality
--              test exists to catch.
-- Change:      v2.0 -- SHOT-READING CHAIN (spec 2026-09-09). New
--              @CounterReading: the press counter reading at the moment the
--              basket was swapped. The operator writes it down at the press
--              and types it here even if they reach the terminal later.
--                * @FinalPieceDelta is now DERIVED from it
--                  (@CounterReading - this CAVITY's watermark) unless the
--                  caller supplies one explicitly, which stays as an override;
--                * the contribution row is written even when the delta is 0,
--                  because that row ANCHORS the cavity watermark -- without it
--                  the next basket on this cavity is credited from the stale
--                  watermark and over-counted;
--                * Tools.Tool.ShotCount now advances here too, by the DELTA.
--                  v1.x deliberately did not touch ShotCount, and that was
--                  right while release dealt only in pieces. Under the reading
--                  model a changeover closes every lot WITHOUT a shift-output
--                  entry ever being made for the outgoing die, so its shots
--                  since the last entry would vanish from its life. Advancing
--                  by (reading - die watermark) cannot double-count.
-- Change:      v1.2 -- shift-override ATTRIBUTION (OI-2 / spec sec 5): new
--              @CellLocationId param (default NULL, backward-compatible) and the
--              final-delta Workorder.DieCastContribution row now stamps
--              CellLocationId -- the PRESS. Mirrors
--              R__Workorder_DieCastShiftOutput_Record.sql v1.4 verbatim,
--              including its fall-back to the die's currently-mounted
--              Tools.ToolAssignment when the caller supplies nothing. Without
--              this the release-time delta would be the one contribution row
--              Oee.ShiftOverride_Restamp could not see.
-- Change:      v1.1 -- pre-transaction defect-code validation: every
--              @ScrapLinesJson[].defectCodeId must exist and be active in
--              Quality.DefectCode, else GOTO Fail with a clean Status=0
--              instead of an in-transaction FK RAISERROR (mirrors
--              RejectEvent_Record's DeprecatedAt check; parity with
--              R__Workorder_DieCastShiftOutput_Record.sql's identical fix).
-- Description: Die-Cast Per-Cavity Lifecycle (plan docs/superpowers/plans/
--              2026-07-28-diecast-per-cavity-lifecycle.md), Task 6 / Phase 3.
--              Closes an open accumulator basket: Open -> Good, moved from its
--              cell to storage (well-known 'WHSE' Location code, resolved when
--              @StorageLocationId is not supplied), carrying an OPTIONAL final
--              good-piece delta (@FinalPieceDelta) + an optional additive scrap
--              batch (@ScrapLinesJson) for the last bit of production that
--              hadn't yet been through Workorder.DieCastShiftOutput_Record.
--
--              Validations (all pre-transaction, FDS-11-011 no-OUTPUT / single
--              terminal result row):
--                required params -> AppUser exists -> LOT exists and is status
--                'Open' -> resolve @StorageLocationId (well-known 'WHSE' when
--                NULL, hard reject if still unresolved; reject if a supplied
--                @StorageLocationId does not exist) -> @ScrapLinesJson well-
--                formed JSON when supplied -> @FinalPieceDelta must not be
--                negative (mirrors DieCastShiftOutput_Record's own guard +
--                DieCastContribution's CHECK (PieceDelta >= 0); the mutation
--                below only applies the delta when > 0, so a negative value
--                must reject rather than silently no-op) -> projected
--                PieceCount (current + ISNULL(@FinalPieceDelta,0)) must be
--                > 0, else reject (an empty basket is Void's job, not
--                Release's).
--
--              Mutation (inlined per the Msg-3915 / INSERT-EXEC rule -- this
--              proc returns a status row and is itself captured via
--              INSERT-EXEC by tests/callers, so it cannot EXEC a sibling
--              status-row proc):
--                * @FinalPieceDelta > 0 -> a Workorder.DieCastContribution
--                  ledger row + row-locked Lot.PieceCount/InventoryAvailable +=
--                  (mirrors R__Workorder_DieCastShiftOutput_Record.sql's
--                  contribution block verbatim).
--                * @ScrapLinesJson present -> additive Workorder.RejectEvent
--                  rows (record-only: no PieceCount decrement, mirrors that
--                  same proc's additive-scrap block verbatim).
--                * Lots.LotStatusHistory Open -> Good; Lots.Lot LotStatusId ->
--                  Good, CurrentLocationId -> storage; Lots.LotMovement
--                  (cell -> storage); Audit.Audit_LogOperation
--                  'DieCastLotReleased' (entity 'Lot').
--
--              @NewId is always NULL -- Release closes an EXISTING lot, it
--              never mints one.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Release
    @LotId BIGINT, @StorageLocationId BIGINT = NULL, @FinalPieceDelta INT = NULL,
    @CounterReading INT = NULL,
    @ScrapLinesJson NVARCHAR(MAX) = NULL, @ShiftId BIGINT = NULL,
    @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL,
    @CellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Lots.DieCastLot_Release';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @LotId AS LotId, @StorageLocationId AS StorageLocationId,
        @FinalPieceDelta AS FinalPieceDelta, @ShiftId AS ShiftId, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ResolvedStorageLocationId BIGINT;

    BEGIN TRY
        -- ---- validations (all pre-transaction) ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       WHERE l.Id = @LotId AND sc.Code = N'Open')
        BEGIN SET @Message = N'LOT not found or not an open basket.'; GOTO Fail; END

        -- resolve storage location (well-known 'WHSE' when not supplied)
        SET @ResolvedStorageLocationId = @StorageLocationId;
        IF @ResolvedStorageLocationId IS NULL
            SET @ResolvedStorageLocationId = (SELECT TOP 1 Id FROM Location.Location
                WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
        IF @ResolvedStorageLocationId IS NULL
        BEGIN SET @Message = N'No storage/warehouse location configured for release.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @ResolvedStorageLocationId)
        BEGIN SET @Message = N'Storage location not found.'; GOTO Fail; END

        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) <> 1
        BEGIN SET @Message = N'ScrapLinesJson is not valid JSON.'; GOTO Fail; END

        -- every scrap defectCodeId must exist and be active -- rejects gracefully
        -- here instead of hitting the FK constraint mid-transaction (mirrors
        -- R__Workorder_RejectEvent_Record.sql's DeprecatedAt check)
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1 AND EXISTS (
            SELECT 1 FROM OPENJSON(@ScrapLinesJson) WITH (defectCodeId BIGINT N'$.defectCodeId') s
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = s.defectCodeId AND dc.DeprecatedAt IS NULL)
        )
        BEGIN SET @Message = N'One or more scrap defect codes are invalid or deprecated.'; GOTO Fail; END

        -- v2.0: resolve the PRESS first -- both watermarks are scoped by it,
        -- and the derived delta below depends on them. (Moved up from after the
        -- projected-count check, which now consumes the derived delta.)
        DECLARE @ResolvedCellLocationId BIGINT = @CellLocationId;
        IF @ResolvedCellLocationId IS NULL
            SELECT TOP 1 @ResolvedCellLocationId = a.CellLocationId
            FROM Tools.ToolAssignment a
            INNER JOIN Lots.Lot l ON l.Id = @LotId
            WHERE a.ToolId = l.ToolId AND a.ReleasedAt IS NULL
            ORDER BY a.AssignedAt DESC, a.Id DESC;

        -- v2.2: @RelItemId joins the pair because the closing scrap rows STAMP
        -- their own identity (0084) rather than reaching it through the LOT.
        DECLARE @RelToolId BIGINT, @RelToolCavityId BIGINT, @RelItemId BIGINT;
        SELECT @RelToolId = ToolId, @RelToolCavityId = ToolCavityId, @RelItemId = ItemId
        FROM Lots.Lot WHERE Id = @LotId;

        IF @CounterReading IS NOT NULL AND @CounterReading < 0
        BEGIN SET @Message = N'Counter reading cannot be negative.'; GOTO Fail; END

        DECLARE @RelDieWatermark INT =
            Workorder.ufn_DieShotWatermark(@RelToolId, @ShiftId, @ResolvedCellLocationId);
        IF @CounterReading IS NOT NULL AND @CounterReading < @RelDieWatermark
        BEGIN
            SET @Message = N'Counter reading ' + CAST(@CounterReading AS NVARCHAR(20))
                         + N' is behind this die'' last recorded reading of '
                         + CAST(@RelDieWatermark AS NVARCHAR(20))
                         + N' for this shift. Check the reading you wrote down.';
            GOTO Fail;
        END

        -- Derive the final delta from the CAVITY watermark unless the caller
        -- overrode it. The operator never subtracts anything.
        IF @CounterReading IS NOT NULL AND @FinalPieceDelta IS NULL
        BEGIN
            SET @FinalPieceDelta = @CounterReading
                - Workorder.ufn_CavityShotWatermark(@RelToolCavityId, @ShiftId, @ResolvedCellLocationId);
            IF @FinalPieceDelta < 0 SET @FinalPieceDelta = 0;
        END

        -- mirrors DieCastShiftOutput_Record's negative-delta guard + DieCastContribution's
        -- CHECK (PieceDelta >= 0): a negative @FinalPieceDelta must reject, not silently
        -- no-op.
        IF @FinalPieceDelta IS NOT NULL AND @FinalPieceDelta < 0
        BEGIN SET @Message = N'FinalPieceDelta cannot be negative.'; GOTO Fail; END

        -- an empty basket is Void's job, not Release's
        DECLARE @ProjectedPieceCount INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId) + ISNULL(@FinalPieceDelta, 0);
        IF @ProjectedPieceCount <= 0
        BEGIN SET @Message = N'Cannot release an empty basket; void it instead.'; GOTO Fail; END

        DECLARE @FromLocationId BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

        -- ===== mutation =====
        BEGIN TRANSACTION;

        -- final good-piece delta (inline, mirrors DieCastShiftOutput_Record's contribution block)
        -- v2.0: written whenever a reading was supplied, even for a ZERO delta --
        -- the row anchors this cavity's watermark. Skipping it would leave the
        -- watermark stale and over-credit the next basket on this cavity.
        IF @CounterReading IS NOT NULL OR (@FinalPieceDelta IS NOT NULL AND @FinalPieceDelta > 0)
        BEGIN
            INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId)
            VALUES (@LotId, @ShiftId, ISNULL(@FinalPieceDelta, 0), @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @ResolvedCellLocationId, @CounterReading, @RelToolCavityId);
            IF ISNULL(@FinalPieceDelta, 0) > 0
            UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
            SET PieceCount = PieceCount + @FinalPieceDelta, InventoryAvailable = InventoryAvailable + @FinalPieceDelta,
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @LotId;

            -- die life advances with the reading (see header)
            DECLARE @RelShotDelta INT = ISNULL(@CounterReading, 0) - @RelDieWatermark;
            IF @RelShotDelta > 0
                UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
                SET ShotCount = ShotCount + @RelShotDelta,
                    UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @RelToolId;
            DECLARE @ContribAct NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
                + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@FinalPieceDelta AS NVARCHAR(10)) + N' pc (final)');
            EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=NULL,
                @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastPieceContributed',
                @LogSeverityCode=N'Info', @Description=@ContribAct, @OldValue=NULL, @NewValue=NULL;
        END

        -- additive final scrap (inline, mirrors DieCastShiftOutput_Record's additive-reject block:
        -- record only, no PieceCount decrement)
        --
        -- v2.2: STAMPS its identity (0084, spec sec 3.3). Die-cast scrap is a
        -- fact about (Shift, Press, Tool, Cavity, Part) and the row carries
        -- that itself -- it is never derived back through the LOT. Until now
        -- this insert kept the pre-0084 column list, and the row it wrote was
        -- unreachable to every cavity-attributed read:
        --   * DieCast_GetShiftOutputBreakdown.PriorScrapThisShift filters
        --     ShiftId + ToolCavityId, so Reconcile Shift's SHIFT SCRAP column
        --     reported 0 for scrap that was genuinely recorded -- permanently,
        --     which is why it presented as a broken Refresh;
        --   * Quality.Reject_GetPartMatrix / _SearchDetail resolve the part
        --     from re.ItemId, so it also showed as an unmapped part.
        -- Every value was already resolved above for the contribution row.
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1
            INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
            SELECT NULL, @LotId, @RelItemId, @RelToolId, @RelToolCavityId, @ShiftId, @ResolvedCellLocationId,
                   s.defectCodeId, s.quantity, NULL, N'Die-cast final release scrap', @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
            FROM OPENJSON(@ScrapLinesJson) WITH (defectCodeId BIGINT '$.defectCodeId', quantity INT '$.quantity') s;

        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@LotId, @OpenStatusId, @GoodStatusId, N'Die-cast basket released to storage.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        UPDATE Lots.Lot
        SET LotStatusId = @GoodStatusId, CurrentLocationId = @ResolvedStorageLocationId,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@LotId, @FromLocationId, @ResolvedStorageLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
            + N' Die Cast ' + Audit.ufn_MidDot() + N' Released to storage');
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@ResolvedStorageLocationId,
            @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastLotReleased',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=NULL;

        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Basket released (' + @LotName + N').';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@LotId,
            @LogEventTypeCode=N'DieCastLotReleased', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing (mirrors Lot_Create /
    -- Lots.DieCastLot_Open's identical guard).
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@LotId,
            @LogEventTypeCode=N'DieCastLotReleased', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
