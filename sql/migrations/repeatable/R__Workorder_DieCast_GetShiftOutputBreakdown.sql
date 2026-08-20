-- ============================================================
-- Repeatable:  R__Workorder_DieCast_GetShiftOutputBreakdown.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     1.3
-- Changelog:   1.3 (2026-08-19) @GrossShots is ADDITIVE, not cumulative. The
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
    @ToolId BIGINT, @ShiftId BIGINT, @GrossShots INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ShiftStart DATETIME2(3) = (SELECT ActualStart FROM Oee.Shift WHERE Id = @ShiftId);
    DECLARE @ShiftEnd   DATETIME2(3) = (SELECT ISNULL(ActualEnd, SYSUTCDATETIME()) FROM Oee.Shift WHERE Id = @ShiftId);

    -- All lots for this tool that were open at any point during the shift window: currently Open,
    -- OR released/closed with a contribution recorded in the shift window.
    ;WITH Lots AS (
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
        lo.ToolCavityId,
        tc.CavityNumber,
        lo.LotId, lo.LotName, lo.IsOpen,
        ISNULL(p.PriorGood, 0) AS PriorGoodThisShift,
        -- proposed good (v1.3, ADDITIVE): a closed lot keeps what it already recorded this
        -- shift; an open lot gets the entered shot count verbatim -- @GrossShots is the
        -- increment SINCE THE OPERATOR'S LAST ENTRY, die-wide, one part per cavity per shot,
        -- so nothing is apportioned and no prior claim is subtracted. Floor at 0 is a
        -- defensive guard only (the write proc rejects a negative gross).
        CASE WHEN lo.IsOpen = 0 THEN ISNULL(p.PriorGood, 0)
             WHEN ISNULL(@GrossShots, 0) < 0 THEN 0
             ELSE ISNULL(@GrossShots, 0)
        END AS ProposedGood,
        CASE WHEN lo.MaxPieceCount IS NULL THEN 2147483647 ELSE lo.MaxPieceCount - lo.PieceCount END AS MaxHeadroom,
        lo.ItemId AS ItemId,
        tc.Description AS CavityDescription
    FROM Lots lo
    INNER JOIN Tools.ToolCavity tc ON tc.Id = lo.ToolCavityId
    LEFT JOIN Prior p ON p.LotId = lo.LotId
    ORDER BY tc.CavityNumber, lo.IsOpen DESC;
END;
GO
