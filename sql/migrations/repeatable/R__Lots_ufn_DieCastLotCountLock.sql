-- ============================================================
-- Repeatable:  R__Lots_ufn_DieCastLotCountLock.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Is this die cast LOT's piece count settled downstream, and why
--              (spec 2026-09-21 sec 3.3)? At trim a total count is entered and
--              that number is what goes forward; once it has been, a die cast
--              shift reconciliation records the production but leaves the count
--              alone. The rule is derived from what is stored, never asked:
--
--                * a Workorder.ProductionEvent at any operation other than
--                  Die Cast -- trim has counted it;
--                * a Lots.LotAttributeChange on PieceCount after the LOT was
--                  released, other than a reconciliation's own (those carry
--                  'Shift reconciliation #...', so reconciling twice is not
--                  self-blocking);
--                * status Closed, or the LOT consumed into another;
--                * any status that blocks production -- Hold, Scrap (A10);
--                  Lots.Lot_RectifyPieceCount refuses those too.
--
--              Inline TVF: ONE row always, so an OUTER APPLY in a read proc
--              never drops a LOT. A NULL @LotId returns IsLocked = 0.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_DieCastLotCountLock (@LotId BIGINT)
RETURNS TABLE
AS
RETURN
SELECT CAST(CASE WHEN x.Reason IS NULL THEN 0 ELSE 1 END AS BIT) AS IsLocked,
       x.Reason AS LockReason
FROM (
    SELECT COALESCE(
        (SELECT TOP 1 N'Counted at ' + oty.Name + N' '
                + CONVERT(NVARCHAR(16), CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120)
         FROM Workorder.ProductionEvent pe
         INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
         INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
         WHERE pe.LotId = @LotId AND oty.Code <> N'DieCast'
         ORDER BY pe.EventAt),
        (SELECT TOP 1 N'Count corrected '
                + CONVERT(NVARCHAR(16), CAST(ac.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120)
         FROM Lots.LotAttributeChange ac
         WHERE ac.LotId = @LotId AND ac.AttributeName = N'PieceCount'
           AND ac.Reason NOT LIKE N'Shift reconciliation #%'
           AND ac.ChangedAt > ISNULL((SELECT MIN(h.ChangedAt) FROM Lots.LotStatusHistory h
                                      INNER JOIN Lots.LotStatusCode o ON o.Id = h.OldStatusId
                                      INNER JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
                                      WHERE h.LotId = @LotId AND o.Code = N'Open' AND n.Code = N'Good'), '9999-12-31')
         ORDER BY ac.ChangedAt),
        (SELECT TOP 1 CASE WHEN sc.Code = N'Closed' THEN N'LOT is closed'
                           ELSE N'LOT is ' + sc.Name END
         FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
         WHERE l.Id = @LotId AND (sc.Code = N'Closed' OR sc.BlocksProduction = 1)),
        (SELECT TOP 1 N'Consumed into another LOT'
         FROM Lots.LotGenealogy g WHERE g.ParentLotId = @LotId)
    ) AS Reason
) x;
GO
