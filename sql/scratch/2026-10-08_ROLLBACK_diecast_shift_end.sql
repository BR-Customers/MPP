-- ROLLBACK for the die cast shift-end release (fe4cf41e). Re-creates the three changed procs exactly as release 0647dc97 had them.
-- Workorder.ufn_CavityCreditedWithoutReading is left in place: nothing calls it after this runs.
-- Import the rollback Ignition archives as well, or the new screens run against the old procs (they tolerate it).
-- ============================================================
-- Repeatable:  R__Workorder_DieCast_GetShiftOutputBreakdown.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-17
-- Version:     3.1
-- Changelog:   3.1 (2026-09-17) ProposedGood for a basket RELEASED earlier
--              this shift is now 0, not PriorGoodThisShift. ProposedGood
--              means one thing on every row: what THIS entry would credit to
--              the basket. A released basket is settled -- it takes scrap
--              only, and Workorder.DieCastShiftOutput_Record rejects any
--              pieceDelta > 0 on it -- so the only proposal the write proc
--              would accept is 0. Returning its shift credit here was a
--              leftover of the v1.0 cumulative split (where the released
--              lot's credit was one share of @GrossShots); it stopped feeding
--              anything at v1.3, and since v2.1 put released rows back on
--              screen every consumer has overridden it (CavityLotRow forces
--              Good to 0, DieCastBody skips the row in its totals and sends
--              pieceDelta 0). The shift credit is still returned, unchanged,
--              as PriorGoodThisShift. Result-set shape unchanged.
--              3.0 (2026-09-14) Reconciliation columns (0084, spec sec 3.2,
--              3.3, 5.2). New @DieWideShots INT = 0 -- shots already booked
--              die-wide this entry. ProposedGood for a still-open lot is now
--              NET of die-wide (floored at 0): today shot loss is purely
--              additive, so a 2,000-shot shift with 20 warm-up shots proposes
--              2,000 good per cavity AND books 20 scrap per cavity -- 2,020
--              parts out of 2,000 shots, and nothing checks. Netting it here
--              means a clean shift balances to zero variance, so a non-zero
--              variance on the reconciliation screen (Task 7) means something
--              actually happened. Three trailing columns APPENDED LAST
--              (existing consumers capture this proc positionally via
--              INSERT-EXEC):
--                * PriorScrapThisShift -- SUM(RejectEvent.Quantity) for this
--                  CAVITY in this SHIFT (IX_RejectEvent_ShiftCavity, 0084).
--                  Shift-scoped, unlike the deleted Lot_GetShiftCavityTally.
--                  RejectSum, which summed a LOT's entire life and over-
--                  reported on a cross-shift basket.
--                * DieWideShots -- @DieWideShots echoed back, so a row can
--                  show raw - dieWide.
--                * IsPending -- 1 when the cavity has no basket (lo.LotId IS
--                  NULL). Spec 3.5/3.6: a basketless cavity's shots are
--                  PENDING, not unaccounted -- they stay behind the cavity's
--                  watermark and credit to the next basket, because that is
--                  where the castings physically are. IsPending sits OUTSIDE
--                  the reconciliation identity and must never be reported as
--                  variance. ProposedGood for a pending row stays 0
--                  (unchanged -- lo.LotId IS NULL branch), the input stays
--                  disabled on the screen (spec 3.5, Task 7).
--              PriorScrapThisShift is NOT netted out of ProposedGood here --
--              only die-wide is. The reconciliation (netShots - cavityScrap)
--              is the screen's job (Task 7); this proc hands over the three
--              independent ingredients.
--              2.2 (2026-09-10) Cavity alpha code (0076): CavityNumber ->
--              CavityCode NVARCHAR(4), and the ordering gains the configured
--              part key. A 12-cavity family die cutting four parts would
--              otherwise render a,a,a,a,b,b,b,b -- four unrelated parts
--              interleaved on the shift-output grid.
--              2.1 (2026-09-09) CAVITY-DRIVEN. The row source was
--              Lots.Lot, so a cavity with no LOT produced no row at all --
--              which is exactly why a Closed or Scrapped cavity was invisible
--              on the die cast screens even though Tools.ToolCavityStatusCode
--              has modelled those states since migration 0010. Rows now come
--              FROM Tools.ToolCavity with the lots LEFT JOINed, so every
--              physical cavity of the die appears every time.
--              A cavity that rolled its basket mid-shift still yields TWO rows
--              (the closed basket and its successor); a cavity with no basket
--              yields one row with NULL lot columns, its status, and the part
--              it is configured to cut (Tools.ToolCavity.ItemId, 0072) -- so
--              the operator can record its scrap and the screen can roll
--              production up per part the way sheet DCFM-2077 does.
--              New trailing columns CavityStatusCode + ConfiguredItemId +
--              ConfiguredPartNumber (APPENDED LAST).
--              2.0 (2026-09-09) SHOT-READING CHAIN. @GrossShots becomes
--              @CounterReading -- the operator now types the PRESS COUNTER
--              READING, not an increment. The counter resets each shift, so
--              every cavity carries a credited-through watermark starting at
--              0 and a basket's credit is (reading - watermark).
--              Renamed rather than reinterpreted: silently changing what a
--              parameter MEANS is exactly how v1.3 came about.
--              A cavity that never rolled has watermark 0 and is credited the
--              whole reading -- v1.3's behaviour exactly. Uniform fan-out is
--              not replaced, it becomes the case where nothing rolled over.
--              New trailing columns CreditedThrough + NewShots (APPENDED LAST;
--              positional INSERT-EXEC consumers only add trailing columns).
--              New @CellLocationId -- the press -- because the watermark is
--              scoped by press so a die move / changeover resets the chain.
--              1.3 (2026-08-19) @GrossShots is ADDITIVE, not cumulative. The
--              open lot on each cavity now proposes @GrossShots DIRECTLY; the
--              old "subtract what every OTHER lot on this cavity already
--              claimed this shift" term is REMOVED. Confirmed with MPP: the
--              operator counts shots SINCE THEIR LAST ENTRY, not off a climbing
--              machine counter, so the number typed is already the increment
--              and backing prior claims out of it double-discounts. Symptom the
--              subtraction produced: a cavity with 6,000 pieces already claimed
--              this shift proposed 0 for ANY entry below 6,000, which reads on
--              the screen exactly like a broken binding. Result-set columns and
--              their ORDER are unchanged -- positional INSERT-EXEC captures are
--              unaffected.
--              1.2 (2026-08-19) added CavityDescription (Tools.ToolCavity.
--              Description) to the result set so the Record Shift Output rows
--              can show the cavity's REAL name instead of the bare ordinal
--              "Cavity <N>" (backlog 2.2). APPENDED LAST, after ItemId, so
--              every existing positional INSERT-EXEC consumer keeps its column
--              order -- temp-table consumers only need one extra trailing
--              NVARCHAR(500) column.
--              1.1 (2026-07-31) added ItemId to the result set (CTE + final
--              SELECT) so the basket-overflow flow can re-open the next basket
--              on the same item. Temp-table consumers must carry ItemId BIGINT.
-- Description: Die-Cast Per-Cavity Lifecycle plan, Task 3 / Phase 2. Pure
--              READ/computation proc: given a tool, a shift, and the shift's
--              gross shot count, returns the proposed per-cavity-lot good-
--              piece split (the auto-breakdown the shift-end recording flow,
--              Workorder.DieCastShiftOutput_Record / Task 4, will present to
--              the operator for confirmation/adjustment before writing
--              Workorder.DieCastContribution rows).
--
--              One row per LOT that was open on this Tool at any point during
--              the shift window: currently status 'Open' (the live basket),
--              OR already released/closed but with a contribution recorded in
--              this shift (a basket that was topped up then released mid-
--              shift).
--
--              @GrossShots IS ADDITIVE -- IT IS THIS ENTRY, NOT A SHIFT TOTAL.
--              The operator counts shots SINCE THEIR LAST ENTRY (they do NOT
--              read a climbing machine counter), so the number handed to this
--              proc is already the increment for this recording. Gross shots
--              are die-wide and every cavity yields one part per shot, so
--              EVERY open lot on the die proposes the SAME entered number --
--              there is nothing to apportion and nothing to back out.
--
--              ProposedGood, therefore:
--                * a non-open (already released/closed-out) lot proposes 0 --
--                  it is settled and takes scrap only (v3.1); what it was
--                  credited this shift is PriorGoodThisShift;
--                * a still-open lot gets @GrossShots verbatim (floored at 0 as
--                  a defensive guard; the write proc
--                  Workorder.DieCastShiftOutput_Record rejects a negative
--                  gross outright).
--              PriorGoodThisShift is still returned -- it is what the screen
--              shows the operator as context and what the peer-terminal
--              concurrency guard baselines against -- but it NO LONGER feeds
--              ProposedGood.
--
--              MaxHeadroom is the cavity lot's remaining capacity
--              (Item.MaxLotSize - PieceCount already on it), or INT_MAX
--              (2147483647) when the item carries no MaxLotSize cap.
--
--              FDS-11-011: no OUTPUT params, one result set, empty set = not
--              found (e.g. an unknown/never-opened @ToolId simply returns no
--              rows -- not an error).
--
--              Deviation from Task 3's brief: the brief's SELECT referenced
--              p.PriorGood (from the Prior CTE) but never joined Prior into
--              the main FROM clause -- Msg 4104 "multi-part identifier
--              'p.PriorGood' could not be bound" on CREATE. Added
--              `LEFT JOIN Prior p ON p.LotId = lo.LotId` (LEFT, not INNER --
--              a lot with no contribution row this shift must still surface
--              with PriorGoodThisShift = 0 via ISNULL, not be dropped).
--              Otherwise verbatim.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId BIGINT, @ShiftId BIGINT, @CounterReading INT,
    @CellLocationId BIGINT = NULL, @DieWideShots INT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- The press. Watermarks are scoped by it (see ufn_CavityShotWatermark).
    -- Fall back to the die's currently-mounted cell when a caller does not
    -- supply one -- correct by construction, since output can only be recorded
    -- on the press the die is on.
    IF @CellLocationId IS NULL
        SELECT TOP 1 @CellLocationId = ta.CellLocationId
        FROM Tools.ToolAssignment ta
        WHERE ta.ToolId = @ToolId AND ta.ReleasedAt IS NULL
        ORDER BY ta.AssignedAt DESC;

    -- Lots that matter this shift: currently Open, or closed but credited in
    -- this shift (those stay visible so their scrap can still be entered at
    -- shift end -- scrap is recorded once, at the end, on a paper form).
    ;WITH Relevant AS (
        SELECT l.Id AS LotId, l.LotName, l.ToolCavityId, l.ItemId, l.PieceCount, l.MaxPieceCount,
               CASE WHEN sc.Code = N'Open' THEN 1 ELSE 0 END AS IsOpen
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.ToolId = @ToolId
          AND ( sc.Code = N'Open'
                OR EXISTS (SELECT 1 FROM Workorder.DieCastContribution c
                           WHERE c.LotId = l.Id AND c.ShiftId = @ShiftId) )
    ),
    Prior AS (   -- good already credited to each lot IN THIS SHIFT
        SELECT c.LotId, SUM(c.PieceDelta) AS PriorGood
        FROM Workorder.DieCastContribution c WHERE c.ShiftId = @ShiftId GROUP BY c.LotId
    )
    SELECT
        tc.Id AS ToolCavityId,
        tc.CavityCode,
        lo.LotId, lo.LotName,
        CAST(ISNULL(lo.IsOpen, 0) AS BIT) AS IsOpen,
        ISNULL(p.PriorGood, 0) AS PriorGoodThisShift,
        -- v2.0: an open basket is credited (reading - its CAVITY watermark). A
        -- basket already closed this shift keeps what it was credited and is
        -- NOT re-credited. A cavity with no basket proposes nothing -- its
        -- shots show as NewShots below, for the operator to record as scrap.
        -- v3.0: a still-open lot's proposal is now NET OF DIE-WIDE (spec
        -- 3.2/3.3), floored at 0. A pending (no-basket) row stays 0.
        -- v3.1: an already-closed-out row also proposes 0 -- it takes scrap
        -- only; its shift credit is PriorGoodThisShift above.
        CASE WHEN lo.LotId IS NULL   THEN 0
             WHEN lo.IsOpen = 0      THEN 0
             ELSE CASE WHEN ISNULL(@CounterReading, 0)
                          - Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId)
                          - ISNULL(@DieWideShots, 0) < 0
                       THEN 0
                       ELSE ISNULL(@CounterReading, 0)
                          - Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId)
                          - ISNULL(@DieWideShots, 0)
                  END
        END AS ProposedGood,
        CASE WHEN lo.LotId IS NULL        THEN 0
             WHEN lo.MaxPieceCount IS NULL THEN 2147483647
             ELSE lo.MaxPieceCount - lo.PieceCount END AS MaxHeadroom,
        lo.ItemId AS ItemId,
        tc.Description AS CavityDescription,
        -- APPENDED (v2.0): context, so the operator can see the system already
        -- did the subtraction and never does it themselves.
        Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId) AS CreditedThrough,
        CASE WHEN ISNULL(@CounterReading, 0)
                    - Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId) < 0
             THEN 0
             ELSE ISNULL(@CounterReading, 0)
                    - Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId)
        END AS NewShots,
        -- APPENDED (v2.1): a cavity with no basket still has a state and a part.
        csc.Code       AS CavityStatusCode,
        tc.ItemId      AS ConfiguredItemId,
        ci.PartNumber  AS ConfiguredPartNumber,
        -- APPENDED (v3.0). Shift-scoped, cavity-keyed -- the number that
        -- exists nowhere today. Reads the new IX_RejectEvent_ShiftCavity path.
        ISNULL((SELECT SUM(re.Quantity) FROM Workorder.RejectEvent re
                WHERE re.ShiftId = @ShiftId AND re.ToolCavityId = tc.Id), 0) AS PriorScrapThisShift,
        @DieWideShots AS DieWideShots,
        CAST(CASE WHEN lo.LotId IS NULL THEN 1 ELSE 0 END AS BIT) AS IsPending
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
    LEFT  JOIN Relevant  lo ON lo.ToolCavityId = tc.Id
    LEFT  JOIN Prior     p  ON p.LotId = lo.LotId
    LEFT  JOIN Parts.Item ci ON ci.Id = tc.ItemId
    WHERE tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
    ORDER BY ci.PartNumber, tc.CavityCode, ISNULL(lo.IsOpen, 0) DESC, lo.LotId;
END;
GO

GO
-- ============================================================
-- Repeatable:  R__Workorder_DieCastCredit_Write.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.1
-- Description: INTERNAL WORKER -- writes ONE die cast credit: a
--              Workorder.DieCastContribution row and, when @ApplyToLot = 1,
--              the matching move of the LOT's materialized PieceCount /
--              InventoryAvailable (B5). Extracted from
--              Workorder.DieCastShiftOutput_Record v3.0 and
--              Lots.DieCastLot_Release v2.2 so the live procs and
--              Workorder.DieCastShiftReconciliation_Save write credits one
--              way (spec 2026-09-21 sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH -- the
--              Oee.ShiftOverride_Restamp pattern. Callers are status-row procs
--              captured via INSERT-EXEC; they validate first, open the
--              transaction, and their CATCH handles anything raised here.
--              This worker validates nothing.
--
--              @ApplyToLot = 0 is the reconciliation's "record the production,
--              leave the count": the LOT is released (its count is corrected
--              through Lots.Lot_ApplyPieceCountCorrection, which leaves the
--              LotAttributeChange trail) or already counted downstream (the
--              count stands -- spec sec 3.3).
--
--              A negative @PieceDelta is legal only with @ReconciliationId;
--              CK_DieCastContribution_DeltaNonNeg enforces it (migration 0097).
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (extracted worker, spec sec 5.1).
--   2026-09-25 - 1.1 - Stamps ShiftAttributionSourceId (migration 0099). See
--                      the comment at the INSERT for why it is derived from
--                      @ReconciliationId here rather than passed in.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastCredit_Write
    @LotId              BIGINT,
    @ShiftId            BIGINT,
    @PieceDelta         INT,
    @CounterReading     INT            = NULL,
    @CellLocationId     BIGINT         = NULL,
    @ApplyToLot         BIT            = 1,
    @VarianceReasonId   BIGINT         = NULL,
    @VarianceNote       NVARCHAR(500)  = NULL,
    @ReconciliationId   BIGINT         = NULL,
    @EventAt            DATETIME2(3)   = NULL,
    @AuditLocationId    BIGINT         = NULL,
    @AuditSuffix        NVARCHAR(100)  = N'',
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @At DATETIME2(3) = ISNULL(@EventAt, SYSUTCDATETIME());

    -- WHERE THE ShiftId CAME FROM (0099). Deliberately DERIVED here rather than
    -- taken as a parameter, because this is the ONLY insert into
    -- Workorder.DieCastContribution in the whole system: making it a parameter
    -- would create exactly the thing 0099 removes -- something a future caller
    -- can forget, silently producing a row the resolver then re-derives.
    -- The rule is total and local: a credit written under a reconciliation
    -- header is a team lead's decision (its @ShiftId is the past shift being
    -- reconciled while @EventAt is now), and every other credit was resolved
    -- from the event time by the caller. No cross-table lookup.
    DECLARE @SourceId BIGINT = (
        SELECT Id FROM Oee.ShiftAttributionSource
        WHERE Code = CASE WHEN @ReconciliationId IS NULL THEN N'Derived' ELSE N'Reconciled' END);

    INSERT INTO Workorder.DieCastContribution
        (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId,
         ShotCounterReading, ToolCavityId, VarianceReasonId, VarianceNote, ReconciliationId,
         ShiftAttributionSourceId)
    SELECT @LotId, @ShiftId, @PieceDelta, @AppUserId, @TerminalLocationId, @At, @CellLocationId,
           @CounterReading, l.ToolCavityId, @VarianceReasonId, @VarianceNote, @ReconciliationId,
           @SourceId
    FROM Lots.Lot l
    WHERE l.Id = @LotId;

    IF @ApplyToLot = 1 AND @PieceDelta <> 0
        UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
        SET PieceCount = PieceCount + @PieceDelta, InventoryAvailable = InventoryAvailable + @PieceDelta,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
    DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@PieceDelta AS NVARCHAR(10)) + N' pc'
        + ISNULL(@AuditSuffix, N''));
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @AuditLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
        @LogEventTypeCode = N'DieCastPieceContributed', @LogSeverityCode = N'Info',
        @Description = @Act, @OldValue = NULL, @NewValue = NULL;
END;
GO

GO
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftOutput_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-25
-- Version:     3.2
-- Change:      v3.2 (2026-09-25) -- pre-transaction validation of a scrap
--              line's approvedByUserId. The check exists because v3.1 made
--              the column WRITABLE from operator JSON: the inline scrap
--              INSERTs it replaced had 14-column lists that did not include
--              ApprovedByUserId at all, so an approvedByUserId key in
--              scrapLines was silently discarded; Workorder.DieCastScrap_Write
--              reads s.approvedByUserId and writes it. A bad id therefore
--              reached Workorder.RejectEvent's FK inside the transaction and
--              surfaced as a generic 'Unexpected error' toast. It now rejects
--              cleanly alongside the defectCodeId check it is modelled on,
--              BEFORE BEGIN TRANSACTION (Msg-3915 rule). Optional stays
--              optional: only a SUPPLIED id that does not resolve to an
--              active (DeprecatedAt IS NULL) Location.AppUser is refused; a
--              line that omits the key or passes null behaves exactly as
--              before. No other validation, and no worker, was touched.
-- Change:      v3.1 (2026-09-22) -- the writes moved into shared workers
--              (spec 2026-09-21 sec 5.1): the contribution + LOT count +
--              audit block is now Workorder.DieCastCredit_Write. Behaviour
--              unchanged; this proc keeps every validation, the watermark
--              guard and the die shot-count update.
--              The per-LOT, per-cavity and die-wide scrap inserts are now
--              Workorder.DieCastScrap_Write, called once after the credits --
--              an ORDERING change, not just an extraction. Pre-3.1, each
--              line's scrap wrote inside the same cursor iteration as its
--              credit (credit, then that line's scrap, then the next line's
--              credit, and so on). v3.1 runs every line's credit first, then
--              calls the scrap worker once, batched, after the cursor closes.
--              This is behaviour-preserving because nothing a scrap insert
--              reads depends on write order: Workorder.DieCastCredit_Write
--              touches only Lot.PieceCount / Lot.InventoryAvailable /
--              Lot.UpdatedAt / Lot.UpdatedByUserId, and no scrap row (per-LOT,
--              per-cavity or die-wide) reads any of those four columns --
--              scrap is additive and record-only (0042 ScrapIsAdditive),
--              stamping its identity from the LOT/cavity/die, never from a
--              piece count. Confirmed safe in code review 2026-09-22.
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

        -- v3.2: an APPROVER named on a scrap line must be a real, active user.
        -- This column only became writable from the operator's JSON in v3.1:
        -- the old inline scrap INSERTs listed 14 columns and ApprovedByUserId
        -- was not among them, so an approvedByUserId key was silently
        -- discarded. Workorder.DieCastScrap_Write reads s.approvedByUserId and
        -- writes it, so from v3.1 a bad id reaches RejectEvent's FK
        -- mid-transaction and the operator sees a generic 'Unexpected error'
        -- instead of something they can act on. Same shape and placement as
        -- the defectCodeId check above; 'active' is DeprecatedAt IS NULL, the
        -- definition Location.AppUser_GetActiveByPin / _GetActiveByInitials
        -- and Location.AppUser_Update all use. OPTIONAL by design: a scrap
        -- line that omits the key, or passes null, is untouched -- only a
        -- SUPPLIED id that does not resolve is refused. The die-wide
        -- (@ShotLossJson) path needs no equivalent check -- the worker writes
        -- NULL there and never reads an approver from that JSON.
        IF EXISTS (
            SELECT 1 FROM @Lines ln
            CROSS APPLY OPENJSON(ln.ScrapLines) WITH (approvedByUserId BIGINT N'$.approvedByUserId') s
            WHERE ln.ScrapLines IS NOT NULL AND ISJSON(ln.ScrapLines) = 1
              AND s.approvedByUserId IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM Location.AppUser u
                              WHERE u.Id = s.approvedByUserId AND u.DeprecatedAt IS NULL)
        )
        BEGIN SET @Message=N'A scrap line''s approver is not an active user; pick the approver again.'; GOTO Fail; END

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
        DECLARE @LotId BIGINT, @Delta INT, @VReasonId BIGINT, @VNote NVARCHAR(500);
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT LotId, PieceDelta, VarianceReasonId, VarianceNote FROM @Lines;
        OPEN cur; FETCH NEXT FROM cur INTO @LotId, @Delta, @VReasonId, @VNote;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- pieces on a basketless line were rejected pre-transaction, so a
            -- credit is only ever written for a line with a LOT (spec 3.6)
            IF @Delta > 0
                EXEC Workorder.DieCastCredit_Write @LotId = @LotId, @ShiftId = @ShiftId, @PieceDelta = @Delta,
                    @CounterReading = @CounterReading, @CellLocationId = @ResolvedCellLocationId, @ApplyToLot = 1,
                    @VarianceReasonId = @VReasonId, @VarianceNote = @VNote, @AuditLocationId = @CellLocationId,
                    @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
            FETCH NEXT FROM cur INTO @LotId, @Delta, @VReasonId, @VNote;
        END
        CLOSE cur; DEALLOCATE cur;

        -- per-LOT, per-cavity and die-wide scrap, additive (record only)
        EXEC Workorder.DieCastScrap_Write @ToolId = @ToolId, @ShiftId = @ShiftId, @CellLocationId = @ResolvedCellLocationId,
            @LinesJson = @LinesJson, @DieWideJson = @ShotLossJson,
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

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

GO
