-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftOutput_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-14
-- Version:     3.0
-- Change:      v3.0 -- die-cast quantity + scrap model, spec sec 5.3. Each
--              @LinesJson line may now carry a bare CAVITY (toolCavityId with
--              a NULL lotId): scrap on such a line writes a RejectEvent with
--              LotId NULL plus ToolCavityId/ItemId/ShiftId/CellLocationId --
--              there is no basket to credit, so PIECES on a basketless line
--              are rejected pre-transaction. A basketless line writes NO
--              DieCastContribution row -- that table's LotId stays NOT NULL
--              (spec 3.6): advancing a basketless cavity's watermark would
--              strand the gap shots behind it and under-credit whichever
--              basket opens next, when those castings are physically INSIDE
--              that next basket. A timing gap on the operator's part must not
--              cost them production. The die-wide (@ShotLossJson) fan-out is
--              re-keyed from open LOTs to ACTIVE CAVITIES (D8) -- the old
--              CROSS JOIN Lots.Lot ... WHERE sc.Code = 'Open' silently
--              skipped every cavity without a basket; it now reaches every
--              Active, non-deprecated Tools.ToolCavity on this tool and
--              attaches the LOT only where one is open. Lines also gain
--              optional varianceReasonId/varianceNote (D15), validated
--              pre-transaction: a supplied reason must exist, and one whose
--              RequiresNote=1 must carry a non-blank note (spec 3.7 --
--              'Unknown' is always available and always requires a note, so a
--              hard block never forces a fabricated defect code). Every new
--              write stays INLINED (never EXEC'd) per the INSERT-EXEC /
--              single-result-set rule; the result-set shape (Status, Message,
--              NewId) is unchanged.
-- Change:      v2.2 -- companion fix for Workorder.ufn_CavityShotWatermark
--              v3.0 (die-cast quantity + scrap model, spec sec 5.3b), which
--              reads DieCastContribution.ToolCavityId directly instead of
--              deriving the cavity via INNER JOIN Lots.Lot. That is only
--              behaviour-preserving if EVERY contribution row still carries
--              its cavity, so the per-line pieces row now stamps ToolCavityId
--              from the line's LOT. Without this, every basket contributed to
--              through this proc would leave its row's cavity unresolvable
--              under v3.0 and the next basket on that cavity would be
--              credited from a stale (zero) watermark -- exactly the
--              regression Task 2's neutrality test exists to catch. The
--              larger cavity-line / cavity-fan-out rewrite (varianceReasonId,
--              basketless scrap lines) is a separate, later change (spec
--              sec 5.3) -- this is only the minimum stamp.
-- Change:      v2.1 -- SCRAP ON A BASKET CLOSED EARLIER THIS SHIFT. MPP
--              records scrap ONCE, at end of shift, from a paper form -- so a
--              basket released mid-shift still needs its scrap entered hours
--              after it closed. The guard required every submitted lot to be
--              'Open', which made that impossible. It now accepts a lot that
--              is Open OR closed-with-a-contribution-in-this-shift (the same
--              set DieCast_GetShiftOutputBreakdown returns), and a separate
--              guard rejects adding PIECES to an already-closed basket -- that
--              one is settled, only its scrap is still outstanding.
-- Change:      v2.0 -- SHOT-READING CHAIN (spec 2026-09-09). @GrossShots
--              becomes @CounterReading: the operator types the PRESS COUNTER
--              READING, not an increment. Renamed rather than reinterpreted.
--                * every contribution row now records ShotCounterReading;
--                * a reading BEHIND the die's watermark for this shift+press
--                  is rejected pre-transaction. That guard catches a typo
--                  (200 for 2000, which would silently under-credit every
--                  cavity) and an out-of-order entry (releasing a basket at a
--                  remembered earlier reading AFTER a shift-output entry
--                  already credited it, which would double-count it);
--                * Tools.ToolCount advances by the DELTA
--                  (@CounterReading - die watermark), never by the raw
--                  reading -- otherwise a second entry in one shift inflates
--                  die life by the whole reading.
-- Change:      v1.4 -- shift-override ATTRIBUTION (OI-2 / spec sec 5): every
--              Workorder.DieCastContribution row now carries CellLocationId --
--              the PRESS -- taken from @CellLocationId, else from the die's
--              currently-mounted Tools.ToolAssignment. Freezes the press against
--              later die moves so Oee.ShiftOverride_Restamp keys on a plain
--              equality instead of re-deriving assignment history.
-- Change:      v1.3 -- FAT #19: new @CellLocationId BIGINT param (the die-cast
--              MACHINE/cell location selected in the entry header). Threaded
--              into the 'DieCastPieceContributed' audit op as @LocationId
--              (was hard-coded NULL) so the event log captures WHICH machine
--              the parts were added at, not just the terminal. Default NULL =
--              backward-compatible; the standalone shot-loss path (no
--              per-cavity lines) emits no DieCastPieceContributed op so is
--              unaffected.
-- Change:      v1.2 -- FAT #26/#27: new @GrossShots INT param; when > 0,
--              increments Tools.Tool.ShotCount for @ToolId in the same txn
--              (materialized die shot counter). Negative gross rejected
--              pre-transaction. NULL/0 = no-op (the shot-loss path never bumps).
-- Change:      v1.1 -- pre-transaction defect-code validation: every
--              scrapLines[].defectCodeId (across all lines) and every
--              shotLoss[].defectCodeId must exist and be active in
--              Quality.DefectCode, else GOTO Fail with a clean Status=0
--              instead of an in-transaction FK RAISERROR (mirrors
--              RejectEvent_Record's DeprecatedAt check).
-- Description: Die-Cast Per-Cavity Lifecycle plan, Task 4 / Phase 2. The
--              shift-output recording WRITE proc: fans the operator-confirmed
--              per-cavity-lot split (Workorder.DieCast_GetShiftOutputBreakdown,
--              Task 3, is the read-side proposal this confirms/adjusts) into
--              open accumulator baskets --
--                * per line: a Workorder.DieCastContribution ledger row +
--                  Lot.PieceCount/InventoryAvailable += net good (@pieceDelta)
--                  + a routed 'Lot'/'DieCastPieceContributed' audit op
--                * per line's scrapLines[]: additive Workorder.RejectEvent rows
--                  (record-only -- die-cast scrap never entered the basket, so
--                  it must NOT decrement PieceCount/InventoryAvailable and must
--                  NOT close the LOT; mirrors R__Workorder_RejectEvent_Record.sql's
--                  @Additive=1 branch, inlined here rather than EXEC'd per the
--                  INSERT-EXEC / single-result-set rule)
--                * @ShotLossJson: an additive RejectEvent fanned across EVERY
--                  currently-Open lot on this tool (a shot-level defect --
--                  e.g. a short shot on the whole cycle -- hits every cavity,
--                  not just one lot's line)
--
--              FDS-11-011 + Msg-3915 rules: ALL rejecting validations
--              (required params, JSON well-formed, AppUser exists, every
--              submitted lot is an Open basket on this tool, no negative
--              pieceDelta) run BEFORE BEGIN TRANSACTION -- this proc is
--              captured via INSERT-EXEC by callers/tests, so a ROLLBACK in an
--              open caller txn throws Msg 3915; CATCH is the only legal
--              ROLLBACK site. All sub-mutations (contribution insert, LOT
--              increment, additive reject inserts) are INLINED rather than
--              EXEC'd against sibling status-row procs. Row-locked
--              UPDLOCK/HOLDLOCK increment per LOT (mirrors Lot_Split /
--              RejectEvent_Record's PieceCount-mutation locking). Single
--              terminal row: Status, Message, NewId (always NULL -- this proc
--              fans out to N lots, there is no single "the" new id).
--
--              Deviation from the Task 4 brief: the brief's Fail: label
--              unconditionally calls Audit.Audit_LogFailure with
--              @AppUserId = @AppUserId, but Audit.FailureLog.AppUserId is
--              NOT NULL/FK -- the very first validation branch (required-
--              parameter check) can be reached with @AppUserId itself NULL,
--              which would throw inside the audit call instead of returning
--              the clean Status=0 row. Lot_Create and Lots.DieCastLot_Open
--              (Task 2) hit and fixed this identical case; mirrored here by
--              guarding the Fail: audit call with an EXISTS check on
--              Location.AppUser. NOTE (2026-08-18): the guard was originally
--              IF @AppUserId IS NOT NULL, which only covers a NULL actor. A
--              non-NULL but NON-EXISTENT id -- exactly what the 'AppUser not
--              found' validation detects, e.g. a session cached against a
--              different database -- passed that guard and violated the FK
--              inside the logger, turning a clean rejection into an unhandled
--              JDBC exception on the operator's screen. Hardened to EXISTS.
--              The brief's RejectEvent INSERT column list (ProductionEventId,
--              LotId, DefectCodeId, Quantity, ChargeToArea, Remarks,
--              AppUserId, RecordedAt) was verified against
--              R__Workorder_RejectEvent_Record.sql / the 0020 table DDL and is
--              correct as written -- no column fix was needed. Otherwise
--              verbatim from the brief.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftOutput_Record
    @ShiftId BIGINT, @ToolId BIGINT, @LinesJson NVARCHAR(MAX),
    @ShotLossJson NVARCHAR(MAX) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL,
    @CounterReading INT = NULL,
    @CellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.DieCastShiftOutput_Record';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ShiftId AS ShiftId, @ToolId AS ToolId, LEFT(@LinesJson,2000) AS LinesJson, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ShiftId IS NULL OR @ToolId IS NULL OR @LinesJson IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.'; GOTO Fail; END
        IF ISJSON(@LinesJson) <> 1 OR (@ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) <> 1)
        BEGIN SET @Message=N'LinesJson/ShotLossJson not valid JSON.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id=@AppUserId) BEGIN SET @Message=N'AppUser not found.'; GOTO Fail; END
        IF @CounterReading IS NOT NULL AND @CounterReading < 0 BEGIN SET @Message=N'Counter reading cannot be negative.'; GOTO Fail; END

        -- v3.0: lotId is now OPTIONAL per line -- a basketless line names a
        -- CAVITY instead (toolCavityId), plus the optional variance
        -- disposition (D15).
        DECLARE @Lines TABLE (LotId BIGINT NULL, ToolCavityId BIGINT NULL, PieceDelta INT NULL,
                               ScrapLines NVARCHAR(MAX), VarianceReasonId BIGINT NULL, VarianceNote NVARCHAR(500) NULL);
        INSERT INTO @Lines (LotId, ToolCavityId, PieceDelta, ScrapLines, VarianceReasonId, VarianceNote)
        SELECT j.lotId, j.toolCavityId, j.pieceDelta, j.scrapLines, j.varianceReasonId, j.varianceNote
        FROM OPENJSON(@LinesJson) WITH (
            lotId BIGINT N'$.lotId', toolCavityId BIGINT N'$.toolCavityId', pieceDelta INT N'$.pieceDelta',
            scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON,
            varianceReasonId BIGINT N'$.varianceReasonId', varianceNote NVARCHAR(500) N'$.varianceNote') j;

        -- v3.0: every line names a LOT or a CAVITY -- neither is not a fact about anything.
        IF EXISTS (SELECT 1 FROM @Lines WHERE LotId IS NULL AND ToolCavityId IS NULL)
        BEGIN SET @Message=N'A line must supply a LOT or a cavity.'; GOTO Fail; END

        -- v2.1: every line lot must be on this tool, and either Open or a
        -- basket closed earlier THIS shift -- the latter so its scrap can still
        -- be entered at shift end. Same set the breakdown read proc returns.
        -- v3.0: scoped to LOT-carrying lines only -- a basketless line (LotId
        -- NULL) is validated separately below, against the cavity instead.
        IF EXISTS (SELECT 1 FROM @Lines ln
                   LEFT JOIN Lots.Lot l ON l.Id=ln.LotId
                   LEFT JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
                   WHERE ln.LotId IS NOT NULL
                     AND ( l.Id IS NULL
                        OR l.ToolId <> @ToolId
                        OR ( sc.Code <> N'Open'
                             AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution c
                                             WHERE c.LotId = l.Id AND c.ShiftId = @ShiftId) ) ))
        BEGIN SET @Message=N'A submitted lot is not a basket on this tool for this shift.'; GOTO Fail; END

        -- ...but a closed basket is SETTLED. It may take scrap, never pieces.
        IF EXISTS (SELECT 1 FROM @Lines ln
                   INNER JOIN Lots.Lot l ON l.Id=ln.LotId
                   INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
                   WHERE sc.Code <> N'Open' AND ISNULL(ln.PieceDelta, 0) > 0)
        BEGIN SET @Message=N'A basket released earlier this shift cannot take more pieces; enter its scrap only.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @Lines WHERE PieceDelta < 0) BEGIN SET @Message=N'pieceDelta cannot be negative.'; GOTO Fail; END

        -- v3.0 (spec 3.5/3.6/5.3): a basketless line names a cavity with no
        -- LOT -- it must resolve to an ACTIVE, non-deprecated cavity on this
        -- tool, and it cannot take pieces: there is no basket to credit, and
        -- crediting it here would be exactly the mistake spec 3.6 forbids
        -- (advancing a watermark with no basket to carry the pieces).
        IF EXISTS (SELECT 1 FROM @Lines ln
                   LEFT JOIN Tools.ToolCavity tc ON tc.Id = ln.ToolCavityId
                   LEFT JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
                   WHERE ln.LotId IS NULL
                     AND ( tc.Id IS NULL OR tc.ToolId <> @ToolId OR tc.DeprecatedAt IS NOT NULL OR csc.Code <> N'Active' ))
        BEGIN SET @Message=N'A basketless line''s cavity is not an active cavity on this tool.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Lines WHERE LotId IS NULL AND ISNULL(PieceDelta, 0) > 0)
        BEGIN SET @Message=N'A basketless line cannot take pieces; there is no basket to credit.'; GOTO Fail; END

        -- v3.0 (D15/spec 3.7): a supplied variance disposition must be a real
        -- reason, and one whose RequiresNote=1 must carry a non-blank note.
        -- 'Unknown' is ALWAYS available and always requires a note -- the
        -- escape hatch is "say you do not know", never a wall that forces a
        -- fabricated defect code.
        IF EXISTS (SELECT 1 FROM @Lines ln WHERE ln.VarianceReasonId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastVarianceReason vr WHERE vr.Id = ln.VarianceReasonId))
        BEGIN SET @Message=N'Variance reason not found.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Lines ln
                   INNER JOIN Workorder.DieCastVarianceReason vr ON vr.Id = ln.VarianceReasonId
                   WHERE vr.RequiresNote = 1 AND LEN(LTRIM(RTRIM(ISNULL(ln.VarianceNote, N'')))) = 0)
        BEGIN SET @Message=N'This variance reason requires a note.'; GOTO Fail; END

        -- every scrap/shot-loss defectCodeId must exist and be active -- rejects
        -- gracefully here instead of hitting the FK constraint mid-transaction
        -- (mirrors R__Workorder_RejectEvent_Record.sql's DeprecatedAt check)
        IF EXISTS (
            SELECT 1 FROM @Lines ln
            CROSS APPLY OPENJSON(ln.ScrapLines) WITH (defectCodeId BIGINT N'$.defectCodeId') s
            WHERE ln.ScrapLines IS NOT NULL AND ISJSON(ln.ScrapLines) = 1
              AND NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = s.defectCodeId AND dc.DeprecatedAt IS NULL)
        )
        OR (@ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) = 1 AND EXISTS (
            SELECT 1 FROM OPENJSON(@ShotLossJson) WITH (defectCodeId BIGINT N'$.defectCodeId') sl
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = sl.defectCodeId AND dc.DeprecatedAt IS NULL)
        ))
        BEGIN SET @Message=N'One or more scrap/shot-loss defect codes are invalid or deprecated.'; GOTO Fail; END

        -- v1.4 (shift-override attribution, OI-2 / spec sec 5): the PRESS this
        -- output was produced on is stamped onto every DieCastContribution row.
        -- Attribution overrides are keyed to the press (design D5), and deriving
        -- it later through Tools.ToolAssignment history means moving the die
        -- months from now would silently re-attribute settled production. The
        -- screen supplies @CellLocationId (FAT #19); when an older caller does
        -- not, fall back to the die's CURRENTLY-MOUNTED cell -- correct by
        -- construction here, because output can only be recorded on the press
        -- the die is on right now. Still NULLable: a die with no active
        -- assignment leaves it NULL and that row is excluded from
        -- equipment-scoped restamps rather than guessed at.
        DECLARE @ResolvedCellLocationId BIGINT = @CellLocationId;
        IF @ResolvedCellLocationId IS NULL
            SELECT TOP 1 @ResolvedCellLocationId = a.CellLocationId
            FROM Tools.ToolAssignment a
            WHERE a.ToolId = @ToolId AND a.ReleasedAt IS NULL
            ORDER BY a.AssignedAt DESC, a.Id DESC;

        -- ===== mutation =====
        -- v2.0: the counter climbs within a shift, so a reading behind what is
        -- already recorded for this die on this press is a typo or an
        -- out-of-order entry. Reject with BOTH numbers -- an operator cannot
        -- act on "invalid reading". Pre-transaction, per the Msg-3915 rule.
        DECLARE @DieWatermark INT =
            Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @ResolvedCellLocationId);
        IF @CounterReading IS NOT NULL AND @CounterReading < @DieWatermark
        BEGIN
            SET @Message = N'Counter reading ' + CAST(@CounterReading AS NVARCHAR(20))
                         + N' is behind this die''s last recorded reading of '
                         + CAST(@DieWatermark AS NVARCHAR(20))
                         + N' for this shift. Check the reading, or release the basket first.';
            GOTO Fail;
        END

        BEGIN TRANSACTION;
        DECLARE @LotId BIGINT, @CavId BIGINT, @Delta INT, @Scrap NVARCHAR(MAX), @VReasonId BIGINT, @VNote NVARCHAR(500);
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT LotId, ToolCavityId, PieceDelta, ScrapLines, VarianceReasonId, VarianceNote FROM @Lines;
        OPEN cur; FETCH NEXT FROM cur INTO @LotId, @CavId, @Delta, @Scrap, @VReasonId, @VNote;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- v3.0: pieces on a basketless line were rejected pre-transaction
            -- above, so @Delta > 0 here is only ever reached with @LotId NOT
            -- NULL -- a contribution row is written ONLY when there is a
            -- basket (spec 3.6/4.7). A basketless line writes no
            -- DieCastContribution row at all, by construction: this whole
            -- block is skipped for it.
            IF @Delta > 0
            BEGIN
                INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId, VarianceReasonId, VarianceNote)
                VALUES (@LotId, @ShiftId, @Delta, @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @ResolvedCellLocationId, @CounterReading,
                        (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @LotId), @VReasonId, @VNote);
                UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
                SET PieceCount = PieceCount + @Delta, InventoryAvailable = InventoryAvailable + @Delta,
                    UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @LotId;
                DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id=@LotId);
                DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
                    + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@Delta AS NVARCHAR(10)) + N' pc');
                EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@CellLocationId,
                    @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastPieceContributed',
                    @LogSeverityCode=N'Info', @Description=@Act, @OldValue=NULL, @NewValue=NULL;
            END
            -- inlined ADDITIVE scrap rows (mirror RejectEvent_Record @Additive=1: record only, no decrement, no close)
            IF @Scrap IS NOT NULL AND ISJSON(@Scrap) = 1
            BEGIN
                IF @LotId IS NOT NULL
                    -- v3.0: a WITH-basket scrap row stamps identity too. The reject
                    -- reports resolve the part from RejectEvent.ItemId now (spec 4.2,
                    -- 5.5) rather than joining through the LOT, so a row written
                    -- without it buckets as '(unassigned part)' -- silently, and on
                    -- the ordinary everyday path, not just the lot-free one. ItemId
                    -- comes from the LOT (authoritative for what is in the basket);
                    -- the cavity, die, shift and press ride along so this row answers
                    -- the same questions the basketless one does.
                    INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
                    SELECT NULL, @LotId, l.ItemId, @ToolId, l.ToolCavityId, @ShiftId, @ResolvedCellLocationId,
                           s.defectCodeId, s.quantity, NULL, N'Die-cast per-cavity scrap', @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
                    FROM OPENJSON(@Scrap) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') s
                    CROSS JOIN Lots.Lot l
                    WHERE l.Id = @LotId;
                ELSE
                    -- v3.0 (spec 3.6/5.3): a basketless line's scrap is a fact
                    -- about the CAVITY -- LotId NULL, plus ToolCavityId,
                    -- ShiftId, CellLocationId and the cavity's ItemId. Pieces
                    -- on this line were already rejected pre-transaction --
                    -- there is no basket to credit, but the pieces are still
                    -- rejected (scrapped) against the cavity.
                    INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
                    SELECT NULL, NULL, tc.ItemId, @ToolId, @CavId, @ShiftId, @ResolvedCellLocationId, s.defectCodeId, s.quantity, NULL, N'Die-cast per-cavity scrap (no basket)', @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
                    FROM OPENJSON(@Scrap) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') s
                    CROSS JOIN Tools.ToolCavity tc
                    WHERE tc.Id = @CavId;
            END
            FETCH NEXT FROM cur INTO @LotId, @CavId, @Delta, @Scrap, @VReasonId, @VNote;
        END
        CLOSE cur; DEALLOCATE cur;

        -- v3.0 (D8): die-wide fan out across ACTIVE CAVITIES, not open LOTs.
        -- The old form (CROSS JOIN Lots.Lot ... WHERE sc.Code = 'Open')
        -- reached only cavities that happened to hold a basket and silently
        -- skipped the rest. It now reaches every Active, non-deprecated
        -- cavity on this tool, stamping each row's cavity and part, and
        -- attaching the LOT only where one is currently open.
        IF @ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) = 1
            INSERT INTO Workorder.RejectEvent
                (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                 DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
            SELECT NULL, ol.LotId, tc.ItemId, @ToolId, tc.Id, @ShiftId, @ResolvedCellLocationId,
                   sl.defectCodeId, sl.quantity, NULL, N'Die-cast die-wide scrap',
                   @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
            FROM OPENJSON(@ShotLossJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') sl
            CROSS JOIN Tools.ToolCavity tc
            INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
            OUTER APPLY (SELECT TOP 1 l.Id AS LotId FROM Lots.Lot l
                         INNER JOIN Lots.LotStatusCode lsc ON lsc.Id = l.LotStatusId
                         WHERE l.ToolCavityId = tc.Id AND lsc.Code = N'Open') ol
            WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND csc.Code = N'Active';

        -- FAT #26/#27: materialized die shot counter. The operator's gross shot
        -- count for this die/shift is the authoritative cycle count; bump it in
        -- the same txn (B5 materialized-quantity pattern, row-locked). NULL/0 =
        -- no-op, so the standalone shot-loss path never double-counts.
        -- v2.0: DELTA, not the raw reading. The watermark advances with every
        -- recorded reading, so release-then-shift-end sums to the shift's
        -- actual shots (1450 + 550 = 2000) and never double-counts.
        DECLARE @ShotDelta INT = ISNULL(@CounterReading, 0) - @DieWatermark;
        IF @ShotDelta > 0
            UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
            SET ShotCount = ShotCount + @ShotDelta,
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ToolId;

        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Shift output recorded.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastPieceContributed', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing (mirrors Lot_Create /
    -- Lots.DieCastLot_Open's identical guard).
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastPieceContributed', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
