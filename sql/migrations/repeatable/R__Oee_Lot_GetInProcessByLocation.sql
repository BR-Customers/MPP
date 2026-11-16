-- ============================================================
-- Repeatable:  R__Oee_Lot_GetInProcessByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-16
-- Version:     1.1
-- Description: READ proc for the Shift-end Summary's "in-process LOTs at this
--              Cell" list (Arc 2 Phase 8, FDS-09-015). LOTs currently at the
--              Location and still in process (status Good or Hold; not Closed /
--              Scrap), with in-process piece count (same derivation as
--              Lots.v_LotDerivedQuantities.TotalInProcess) and the latest
--              arrival time into this Location from LotMovement (uses the
--              (ToLocationId, MovedAt DESC) index). READ proc: one result set;
--              empty set = none. Arrival time converted to Eastern (OI-36).
--
-- Change log:
--   1.0  2026-06-16  Initial.
--   1.1  2026-11-16  Performance only; result set unchanged (columns, types,
--                    rows, order). Two changes:
--                    (a) the in-process count no longer joins
--                        Lots.v_LotDerivedQuantities. The view's two GROUP BYs
--                        were never pushed down to the LOTs in scope, so every
--                        call scanned and hash-aggregated ALL of
--                        Workorder.ConsumptionEvent (which only grows) to answer
--                        for a few dozen LOTs. The same formula is now computed
--                        per LOT with two seeks (CIX on SourceLotId; filtered
--                        IX_ConsumptionEvent_ProducedLotId on ProducedLotId).
--                        KEEP IN STEP with v_LotDerivedQuantities.TotalInProcess
--                        (produced into the LOT minus consumed from it); test
--                        0026/140 asserts the two agree.
--                    (b) the literal AND l.LotStatusId <> 4 (Closed) beside the
--                        code-table test, so IX_Lot_NotClosed_Location (0118)
--                        can serve the Location seek. Redundant with
--                        sc.Code IN (Good, Hold); same pattern as PRs 9/14/20-22.
--                    Measured on a 41k-LOT / 116k-ConsumptionEvent load: warm
--                    109 ms -> 7 ms, about 102k -> 2.7k logical reads.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.Lot_GetInProcessByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT l.Id                    AS LotId,
           l.LotName               AS LotName,
           i.PartNumber            AS ItemCode,
           -- Mirror of Lots.v_LotDerivedQuantities.TotalInProcess, scoped to this LOT.
           CAST(ISNULL((SELECT SUM(cp.PieceCount) FROM Workorder.ConsumptionEvent cp
                        WHERE cp.ProducedLotId = l.Id), 0)
              - ISNULL((SELECT SUM(cs.PieceCount) FROM Workorder.ConsumptionEvent cs
                        WHERE cs.SourceLotId = l.Id), 0) AS INT) AS InProcessPieceCount,
           sc.Code                 AS LotStatus,
           CAST(m.MovedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAtEt
    FROM Lots.Lot l
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    OUTER APPLY (SELECT TOP 1 lm.MovedAt FROM Lots.LotMovement lm
                 WHERE lm.LotId = l.Id AND lm.ToLocationId = @LocationId
                 ORDER BY lm.MovedAt DESC) m
    WHERE l.CurrentLocationId = @LocationId
      AND sc.Code IN (N'Good', N'Hold')
      AND l.LotStatusId <> 4      -- Closed; literal so IX_Lot_NotClosed_Location applies
    ORDER BY m.MovedAt DESC, l.Id ASC;
END;
GO
