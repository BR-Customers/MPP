-- ============================================================
-- Repeatable:  R__Lots_Lot_GetShiftCavityTally.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.1
-- Description: Arc 2 Phase 3 die-cast right-rail "shots this shift" tally.
--              For the die mounted at a machine, returns ONE ROW PER ACTIVE
--              (configured) ToolCavity with the sum of as-cast PieceCount of
--              LOTs Created during the current OEE shift on that tool+cavity,
--              plus ShiftShots = MAX(that sum) OVER all cavities.
--
--              v1.1 (2026-07-06, Jacques meeting): the tally now REFLECTS SCRAP.
--              RejectEvent_Record DECREMENTS Lot.PieceCount, so summing the live
--              PieceCount silently dropped scrapped parts from the shift count.
--              Each lot now contributes PieceCount + SUM(RejectEvent.Quantity)
--              (its true as-cast total), and a new RejectSum column exposes the
--              per-cavity scrapped quantity for the card.
--
--              Domain (per MPP, 2026-06-17): die-cast LOTs are never "in
--              process" -- parts are cast until a basket fills, then the LOT is
--              Created at the terminal and moved straight to storage. So there
--              is no "active LOT"; the useful machine metric is the per-cavity
--              shift production. Because every cavity of a die fires on the same
--              shot, the busiest cavity's piece total is the most accurate shot
--              count -> ShiftShots = MAX across cavities.
--
--              Keyed on @ToolId (the die mounted at the machine), NOT on the
--              LOT's CurrentLocationId -- the LOT moves to storage right after
--              creation, so CurrentLocationId is stale, but Lot.ToolId /
--              Lot.ToolCavityId are stamped at creation and immutable.
--
--              Pieces summed = Lot.PieceCount + rejected quantity (the as-cast
--              count; PieceCount alone drops on rejects) -- a shot fired even
--              if its part is later scrapped.
--
--              Shift window = the open OEE shift's ActualStart (B3 single-open
--              invariant -> at most one). Falls back to start-of-day (UTC) when
--              no shift is open (dev/smoke where shifts aren't ticked) so the
--              card is not blank.
--
--              LEFT JOIN to Lot so a configured cavity with zero shots this
--              shift still returns a row (the dropdown lists every cavity).
--
--              Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty result set = the tool has no active cavities.
--              No mutation, no transaction, no audit.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetShiftCavityTally
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ShiftStart DATETIME2(3) =
        (SELECT TOP 1 s.ActualStart
         FROM Oee.Shift s
         WHERE s.ActualEnd IS NULL
         ORDER BY s.ActualStart DESC);

    IF @ShiftStart IS NULL
        SET @ShiftStart = CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(3));

    SELECT
        tc.Id                                          AS ToolCavityId,
        tc.CavityNumber                                AS CavityNumber,
        CONCAT(N'Cavity ', tc.CavityNumber)            AS CavityLabel,
        ISNULL(SUM(l.PieceCount + ISNULL(rj.RejectedQty, 0)), 0) AS PieceSum,
        ISNULL(SUM(rj.RejectedQty), 0)                 AS RejectSum,
        ISNULL(MAX(SUM(l.PieceCount + ISNULL(rj.RejectedQty, 0))) OVER (), 0) AS ShiftShots,
        -- Press-totals (identical on every row) for the right-rail KPIs, added 2026-07-21:
        -- ShiftGoodTotal = net good across ALL cavities (live PieceCount = as-cast minus
        -- scrap); ShiftScrapTotal = scrapped qty across ALL cavities. Not cavity-scoped.
        ISNULL(SUM(SUM(l.PieceCount)) OVER (), 0)                             AS ShiftGoodTotal,
        ISNULL(SUM(SUM(ISNULL(rj.RejectedQty, 0))) OVER (), 0)                AS ShiftScrapTotal
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    LEFT JOIN Lots.Lot l
           ON l.ToolCavityId = tc.Id
          AND l.ToolId       = @ToolId
          AND l.CreatedAt    >= @ShiftStart
    OUTER APPLY (SELECT SUM(re.Quantity) AS RejectedQty
                 FROM Workorder.RejectEvent re
                 WHERE re.LotId = l.Id) rj
    WHERE tc.ToolId = @ToolId
      AND sc.Code   = N'Active'
    GROUP BY tc.Id, tc.CavityNumber
    ORDER BY tc.CavityNumber;
END;
GO
