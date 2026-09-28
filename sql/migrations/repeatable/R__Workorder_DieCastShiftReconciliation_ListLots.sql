-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListLots.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.3
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 6.2).
--   2026-09-25 - 1.1 - Dropped the ISNULL(ProducedAtLocationId, @CellLocationId)
--                      fallback in the opened-during-the-shift branch. It let a LOT
--                      with no press appear under EVERY press. ProducedAtLocationId
--                      is never NULL on a cast part, so the fallback only ever
--                      masked bad data. See the comment at the predicate.
--   2026-09-28 - 1.2 - Documentation only, no query change: records why there is
--                      no cavity predicate, alongside Save 1.7.
--   2026-09-28 - 1.3 - Documentation only, no query change: retarget that note
--                      at Save 1.8, which dropped 1.7's CreatedAt lower bound
--                      after production measurement. The note's own point is
--                      unchanged -- this read still has no cavity predicate.
-- Description: Every LOT the reconciliation screen lists for this shift x
--              press x die: the ones credited in the shift, plus any opened on
--              this die during it (an Open LOT at zero still belongs on the
--              list). Recorded is what this SHIFT credited; PieceCount is the
--              LOT's own total. IsLocked / LockReason come from
--              Lots.ufn_DieCastLotCountLock -- spec sec 3.3's three states are
--              Open (credit), released-and-clean (correct), locked (stands).
--              Ordered part, then cavity, then LTT -- the press sheet's order.
--
--              NO CAVITY FILTER HERE, AND THAT IS DELIBERATE (noted 1.2).
--              Tools.ToolCavity is LEFT-joined for the cavity code only; a LOT
--              is selected by its own production and its own die, never by
--              whether the cavity that cast it is still on the die today. A
--              basket made on a since-deprecated cavity is still a basket, and
--              it must appear on the list the team lead reconciles from. Do not
--              add a DeprecatedAt or status predicate to that join --
--              Workorder.DieCastShiftReconciliation_Save 1.8 keeps a cavity
--              deprecated AFTER the shift in ITS set so the two agree.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListLots
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StartEt DATETIME2(3), @EndEt DATETIME2(3);
    SELECT @StartEt = s.ActualStart, @EndEt = s.ActualEnd FROM Oee.Shift s WHERE s.Id = @ShiftId;
    DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @EndUtc DATETIME2(3) = CASE WHEN @EndEt IS NULL THEN SYSUTCDATETIME()
                                        ELSE CAST(@EndEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END;

    ;WITH rec AS (
        SELECT c.LotId, SUM(c.PieceDelta) AS Recorded
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId
        GROUP BY c.LotId
    ),
    ids AS (
        SELECT LotId FROM rec
        UNION
        SELECT l.Id FROM Lots.Lot l
        WHERE l.ToolId = @ToolId AND l.CreatedAt >= @StartUtc AND l.CreatedAt < @EndUtc
          -- Compared on the real column. v1.0 wrote
          -- ISNULL(l.ProducedAtLocationId, @CellLocationId) = @CellLocationId, which
          -- admitted a LOT with NO press as if it belonged to whichever press was
          -- being viewed -- so another machine's basket could land in this press's
          -- reconciliation. INVARIANT: ProducedAtLocationId is never NULL on a cast
          -- part (every die cast mint stamps it). A NULL is therefore a data defect,
          -- and a defect must not be papered over by a read: it simply does not
          -- match here, and the LOT is absent rather than wrong.
          AND l.ProducedAtLocationId = @CellLocationId
    )
    SELECT l.Id AS LotId, l.LotName AS Ltt, l.ItemId, i.PartNumber, i.Description AS PartDescription,
           l.ToolCavityId, tc.CavityCode, ISNULL(rec.Recorded, 0) AS Recorded,
           l.PieceCount, l.InventoryAvailable, sc.Code AS StatusCode, sc.Name AS StatusName,
           cl.Name AS NowAt, rel.ReleasedAtEt, lk.IsLocked, lk.LockReason
    FROM ids
    INNER JOIN Lots.Lot l ON l.Id = ids.LotId
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    LEFT JOIN Location.Location cl ON cl.Id = l.CurrentLocationId
    LEFT JOIN rec ON rec.LotId = l.Id
    OUTER APPLY (SELECT MIN(CAST(h.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))) AS ReleasedAtEt
                 FROM Lots.LotStatusHistory h
                 INNER JOIN Lots.LotStatusCode o ON o.Id = h.OldStatusId
                 INNER JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
                 WHERE h.LotId = l.Id AND o.Code = N'Open' AND n.Code = N'Good') rel
    OUTER APPLY Lots.ufn_DieCastLotCountLock(l.Id) lk
    ORDER BY i.PartNumber, tc.CavityCode, l.LotName;
END;
GO
