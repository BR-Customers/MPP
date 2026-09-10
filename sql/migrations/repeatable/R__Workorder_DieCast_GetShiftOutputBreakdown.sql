-- ============================================================
-- Repeatable:  R__Workorder_DieCast_GetShiftOutputBreakdown.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     2.1
-- Changelog:   2.1 (2026-09-09) CAVITY-DRIVEN. The row source was
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
--                * a non-open (already released/closed-out) lot keeps whatever
--                  it was credited this shift -- PriorGoodThisShift, unchanged;
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
    @CellLocationId BIGINT = NULL
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
        tc.CavityNumber,
        lo.LotId, lo.LotName,
        CAST(ISNULL(lo.IsOpen, 0) AS BIT) AS IsOpen,
        ISNULL(p.PriorGood, 0) AS PriorGoodThisShift,
        -- v2.0: an open basket is credited (reading - its CAVITY watermark). A
        -- basket already closed this shift keeps what it was credited and is
        -- NOT re-credited. A cavity with no basket proposes nothing -- its
        -- shots show as NewShots below, for the operator to record as scrap.
        CASE WHEN lo.LotId IS NULL   THEN 0
             WHEN lo.IsOpen = 0      THEN ISNULL(p.PriorGood, 0)
             ELSE CASE WHEN ISNULL(@CounterReading, 0)
                          - Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId) < 0
                       THEN 0
                       ELSE ISNULL(@CounterReading, 0)
                          - Workorder.ufn_CavityShotWatermark(tc.Id, @ShiftId, @CellLocationId)
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
        ci.PartNumber  AS ConfiguredPartNumber
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
    LEFT  JOIN Relevant  lo ON lo.ToolCavityId = tc.Id
    LEFT  JOIN Prior     p  ON p.LotId = lo.LotId
    LEFT  JOIN Parts.Item ci ON ci.Id = tc.ItemId
    WHERE tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
    ORDER BY tc.CavityNumber, ISNULL(lo.IsOpen, 0) DESC, lo.LotId;
END;
GO
