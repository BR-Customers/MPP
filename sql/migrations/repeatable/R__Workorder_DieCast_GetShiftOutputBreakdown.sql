-- ============================================================
-- Repeatable:  R__Workorder_DieCast_GetShiftOutputBreakdown.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-29
-- Version:     1.0
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
--              shift). ProposedGood: a non-open (already-closed-out) lot keeps
--              whatever it was credited this shift; the still-open lot(s) get
--              the remainder of @GrossShots after subtracting what every
--              OTHER lot on that lot's cavity already claimed this shift
--              (floored at 0 -- never negative). MaxHeadroom is the cavity
--              lot's remaining capacity (Item.MaxLotSize - PieceCount already
--              on it), or INT_MAX (2147483647) when the item carries no
--              MaxLotSize cap.
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
        SELECT l.Id AS LotId, l.LotName, l.ToolCavityId, l.PieceCount, l.MaxPieceCount,
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
        -- proposed good: a closed lot keeps what it recorded; the open lot gets the remainder of gross
        CASE WHEN lo.IsOpen = 0 THEN ISNULL(p.PriorGood, 0)
             ELSE CASE WHEN @GrossShots - ISNULL((SELECT SUM(c2.PieceDelta) FROM Workorder.DieCastContribution c2
                          INNER JOIN Lots.Lot l2 ON l2.Id = c2.LotId
                          WHERE c2.ShiftId = @ShiftId AND l2.ToolCavityId = lo.ToolCavityId AND c2.LotId <> lo.LotId), 0) < 0
                       THEN 0
                       ELSE @GrossShots - ISNULL((SELECT SUM(c2.PieceDelta) FROM Workorder.DieCastContribution c2
                          INNER JOIN Lots.Lot l2 ON l2.Id = c2.LotId
                          WHERE c2.ShiftId = @ShiftId AND l2.ToolCavityId = lo.ToolCavityId AND c2.LotId <> lo.LotId), 0)
                  END
        END AS ProposedGood,
        CASE WHEN lo.MaxPieceCount IS NULL THEN 2147483647 ELSE lo.MaxPieceCount - lo.PieceCount END AS MaxHeadroom
    FROM Lots lo
    INNER JOIN Tools.ToolCavity tc ON tc.Id = lo.ToolCavityId
    LEFT JOIN Prior p ON p.LotId = lo.LotId
    ORDER BY tc.CavityNumber, lo.IsOpen DESC;
END;
GO
