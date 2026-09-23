-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListLots.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Every LOT the reconciliation screen lists for this shift x
--              press x die: the ones credited in the shift, plus any opened on
--              this die during it (an Open LOT at zero still belongs on the
--              list). Recorded is what this SHIFT credited; PieceCount is the
--              LOT's own total. IsLocked / LockReason come from
--              Lots.ufn_DieCastLotCountLock -- spec sec 3.3's three states are
--              Open (credit), released-and-clean (correct), locked (stands).
--              Ordered part, then cavity, then LTT -- the press sheet's order.
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
          AND ISNULL(l.ProducedAtLocationId, @CellLocationId) = @CellLocationId
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
