-- ============================================================
-- Repeatable:  R__Lots_ufn_NextPendingRouteStep.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-20
-- Version:     1.3
-- Description: THE single definition of "what is this LOT's next pending route
--              step". Extracted from seven copy-pasted CTEs across five procs
--              (Lots.Lot_GetWipQueueByLocation, Lots.Lot_GetComponentsAtCell,
--              Lots.Lot_GetTrimStorageQueueForLine, Lots.Lot_MoveToValidated,
--              and THREE inside Workorder.MachiningOut_Mint). Behaviour is
--              identical to those copies -- this is a pure extraction.
--
--              v1.1 (2026-09-12): honours Lots.Lot.EntryRouteSequence (migration
--              0080). Route steps below a LOT's entry point are never pending --
--              that is how inventory counted in at cutover surfaces at the
--              terminal where it physically sits rather than at the first route
--              step. NULL = entry at the route start = today's behaviour.
--
--              v1.2 (2026-10-19): a trim REWORK re-arms Advance steps. Lots.LotRework
--              (migration 0112) holds one row per supervisor-approved override move
--              back into trim. For the LOT's most recent rework, an Advance step at or
--              above ReEntrySequenceNumber counts as done only by a ProductionEvent
--              recorded at/after StartedAt; steps below the re-entry point, and LOTs
--              with no rework row, keep the v1.1 rule. EntryRouteSequence is still
--              applied separately, so a rework never re-arms anything below entry
--              (superseded by v1.3).
--
--              v1.3 (2026-10-20, final review I-1): the latest rework LOWERS the LOT's
--              effective entry point. Effective entry = ISNULL(EntryRouteSequence, 0),
--              unless the LOT's most recent LotRework re-entered at a LOWER step, in
--              which case that re-entry step. Without this, a LOT counted in at cutover
--              above TrimIn (EntryRouteSequence = MachiningIn) and override-moved back
--              into trim got a rework whose TrimIn/TrimOut steps were never pending --
--              off every trim queue, so the Trim OUT that closes the rework was
--              unreachable and a super-lot release stayed blocked. A rework is the
--              plant saying "this LOT re-enters the route here", so it re-enters there.
--              Inert for a LOT with no rework (rw columns NULL) and for a rework at or
--              above entry. The re-arm rule (>= ReEntry counts only events at/after
--              StartedAt; '>=' because the move and the next event can share a
--              millisecond and nothing is recorded between them) is unchanged.
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
    -- The LOT's most recent rework, if any (NULLs when it has never been reworked).
    OUTER APPLY (SELECT TOP (1) lr.ReEntrySequenceNumber, lr.StartedAt
                 FROM Lots.LotRework lr
                 WHERE lr.LotId = l.Id
                 ORDER BY lr.StartedAt DESC, lr.Id DESC) rw
    WHERE l.Id = @LotId
      -- Steps below the LOT's effective entry point are not part of its journey.
      -- NULL EntryRouteSequence (every pre-cutover row) means entry at the route
      -- start. The latest rework lowers the entry to its re-entry step (v1.3).
      AND rs.SequenceNumber >= CASE WHEN rw.ReEntrySequenceNumber < ISNULL(l.EntryRouteSequence, 0)
                                    THEN rw.ReEntrySequenceNumber
                                    ELSE ISNULL(l.EntryRouteSequence, 0) END
      AND (
              rk.Code = N'ConsumeMint'
           OR (rk.Code = N'Advance' AND NOT EXISTS (
                  SELECT 1 FROM Workorder.ProductionEvent pe
                  WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId
                    AND (   rw.StartedAt IS NULL
                         OR rs.SequenceNumber < rw.ReEntrySequenceNumber
                         OR pe.EventAt >= rw.StartedAt)))
          )
    ORDER BY rs.SequenceNumber ASC;
GO
