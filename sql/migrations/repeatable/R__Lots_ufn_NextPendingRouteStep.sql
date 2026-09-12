-- ============================================================
-- Repeatable:  R__Lots_ufn_NextPendingRouteStep.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: THE single definition of "what is this LOT's next pending route
--              step". Extracted from seven copy-pasted CTEs across five procs
--              (Lots.Lot_GetWipQueueByLocation, Lots.Lot_GetComponentsAtCell,
--              Lots.Lot_GetTrimStorageQueueForLine, Lots.Lot_MoveToValidated,
--              and THREE inside Workorder.MachiningOut_Mint). Behaviour is
--              identical to those copies -- this is a pure extraction.
--
--              Pending depends on the step's OperationRoleKind:
--                * Advance     -> pending until a matching Workorder.ProductionEvent
--                                 exists for the LOT on that step's OperationTemplateId.
--                * OriginMint  -> never pending (the LOT exists => it was minted there).
--                * ConsumeMint -> always pending while the LOT is open; it is the
--                                 terminal step and the LOT leaves only by closing.
--                                 This is what keeps a decrementing casting in the
--                                 Machining OUT queue across repeated partial mints.
--
--              SCOPE -- read this before adding anything. This function answers
--              ONLY the route question. It does NOT filter by LOT status or by
--              location, because those predicates differ per caller:
--              Lot_GetWipQueueByLocation excludes Closed AND Open, while its
--              siblings exclude only Closed, and each caller scopes location its
--              own way. Folding either into this function would silently change
--              behaviour for at least one caller. Callers keep their own filters.
--
--              INLINE TVF on purpose (not scalar, not multi-statement) so the
--              optimiser folds it into the caller's plan. These procs run on
--              every terminal refresh; a multi-statement TVF would put a
--              row-by-row barrier in the hot path.
--
--              Ordering note: repeatable scripts deploy alphabetically, so the
--              procs that CROSS APPLY this function are created before it
--              exists. That is safe -- a TVF in a FROM/APPLY clause resolves
--              like a table reference and is subject to deferred name
--              resolution. R__Audit_OperatorChange_Log / R__Audit_ufn_MidDot
--              are the existing precedent for the same ordering.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_NextPendingRouteStep (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT TOP (1)
           rs.SequenceNumber        AS SequenceNumber,
           rs.OperationTemplateId   AS OperationTemplateId,
           oty.Code                 AS OperationTypeCode
    FROM Lots.Lot l
    INNER JOIN Parts.RouteTemplate rt      ON rt.ItemId = l.ItemId
         AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
    INNER JOIN Parts.RouteStep rs          ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty.OperationRoleKindId
    WHERE l.Id = @LotId
      AND (
              rk.Code = N'ConsumeMint'
           OR (rk.Code = N'Advance' AND NOT EXISTS (
                  SELECT 1 FROM Workorder.ProductionEvent pe
                  WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
          )
    ORDER BY rs.SequenceNumber ASC;
GO
