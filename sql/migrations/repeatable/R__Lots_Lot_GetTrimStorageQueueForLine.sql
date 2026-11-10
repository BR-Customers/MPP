-- ============================================================
-- Repeatable:  R__Lots_Lot_GetTrimStorageQueueForLine.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-10
-- Version:     2.1
-- Description: THE Machining IN queue read for ONE machining line.
--
--              *** THE NAME IS HISTORIC. This proc no longer looks at Trim Storage. ***
--              It was written for the Trim-Storage model (2026-07-23), when every part
--              went through a trim shop and "claimable stock" and "stock in Trim Storage"
--              were the same set. Some oil pans skip trim entirely; their route is
--              DieCast -> MachiningIn -> AssemblyOut and a released basket sits in WHSE.
--              The name is kept only because renaming it would force an edit to the
--              MachiningIn view's binding expression (a Designer change). See spec
--              2026-09-15-machining-in-route-driven-claim-design.md section 5.
--
--              v2.1 (2026-11-10, prod incident -- notes/2026-11-10_prod-incident-
--              assembly-out-deadlock.md): same rows, same order, no longer a heap
--              scan. v2.0 put every open LOT in the plant through the route function
--              before the eligibility test and aggregated ALL of Lots.LotMovement per
--              call, so it scanned the Lots.Lot heap with page locks and went
--              parallel. Now: eligible Items into @Items, their open LOTs into @Lots by
--              seek on IX_Lot_NotClosed_Item (0118), last movement by per-LOT seek.
--
--              v2.0 (2026-09-15): THE ROUTE IS THE GATE. Returns the LOTs -- wherever
--              they physically sit -- whose next PENDING route step is MachiningIn and
--              whose Item is ELIGIBLE at @LineLocationId (ancestor cascade). Trim Storage
--              is now just one of several places such a LOT may be; WHSE is another.
--
--              A part eligible at two lines appears in both lines' reads. Claiming it
--              (Workorder.MachiningIn_RecordPick) writes the MachiningIn ProductionEvent,
--              which SATISFIES that Advance step -- so the LOT drops off every line's
--              read by route, not by having been moved out of a storage location.
--
--              @StorageLocationId is ACCEPTED AND IGNORED (v2.0). It restricted the read
--              to one shop's trim store under the old model and is meaningless now; it
--              is retained so the named query's signature stays byte-identical. Compare
--              @DestinationCellLocationId on Workorder.TrimOut_Record.
--
--              Same column shape as Lots.Lot_GetWipQueueByLocation so the view row
--              transform is unchanged. Read proc: no OUTPUT params, single result set,
--              empty set = nothing to show (FDS-11-011). Pending logic lives in
--              Lots.ufn_NextPendingRouteStep (Advance pending until a matching
--              ProductionEvent; ConsumeMint always pending while open; OriginMint never
--              pending). FIFO by CastDate then arrival.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetTrimStorageQueueForLine
    @LineLocationId    BIGINT,
    @StorageLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. The Items eligible at this line (ancestor cascade). v2.1: resolved FIRST so
    --    step 2 reads only those Items' LOTs; v2.0 ran every open LOT in the plant
    --    through the route function and applied this test last.
    DECLARE @Items TABLE (ItemId BIGINT NOT NULL PRIMARY KEY);
    INSERT INTO @Items (ItemId)
    SELECT DISTINCT eil.ItemId
    FROM Parts.v_EffectiveItemLocation eil
    WHERE eil.ItemId IS NOT NULL
      AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LineLocationId));

    -- 2. Candidate LOTs of those Items, ANYWHERE. v2.0 (2026-09-15): location is no longer a gate --
    -- see the header. Status filtering stays HERE (the shared pending-step function
    -- filters neither status nor location):
    --   Closed -> finished, nothing pending.
    --   Open   -> a die-cast basket still being FILLED. It must not be claimable, and
    --             without this it WOULD surface on a trim-skipping route (DieCast is
    --             OriginMint, so MachiningIn is already "next" while the basket fills).
    --             Mirrors Lot_GetWipQueueByLocation, which excludes both.
    -- Held/blocked LOTs are deliberately NOT excluded: the Machining IN screen shows
    -- them and counts them in its "On Hold" indicator. MachiningIn_RecordPick refuses
    -- the claim, which is the intended visible-but-not-claimable behaviour.
    -- 'LotStatusId <> 4' repeats IX_Lot_NotClosed_Item's filter (0118) so the
    -- optimiser seeks it; the code-table join is what actually decides.
    DECLARE @Lots TABLE (LotId BIGINT NOT NULL PRIMARY KEY);
    INSERT INTO @Lots (LotId)
    SELECT l.Id
    FROM @Items it
    INNER JOIN Lots.Lot l            ON l.ItemId = it.ItemId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                                    AND sc.Code NOT IN (N'Closed', N'Open')
    WHERE l.LotStatusId <> 4;

    -- 3. Each candidate with its next PENDING route step; keep those at MachiningIn.
    --    LastMovementAt is a per-LOT seek on CIX_LotMovement_LotMovedAt (v2.1; v2.0
    --    aggregated the whole LotMovement table on every call).
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.LotStatusId, sc.Code AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        oty.Code AS NextOperationTypeCode,
        ns.SequenceNumber AS NextSequenceNumber
    FROM @Lots e
    CROSS APPLY Lots.ufn_NextPendingRouteStep(e.LotId) ns
    INNER JOIN Lots.Lot l               ON l.Id = e.LotId
    INNER JOIN Lots.LotStatusCode sc    ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i             ON i.Id  = l.ItemId
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = ns.OperationTemplateId
    INNER JOIN Parts.OperationType oty  ON oty.Id = ot.OperationTypeId
    OUTER APPLY (SELECT MAX(m.MovedAt) AS LastMovementAt
                 FROM Lots.LotMovement m WHERE m.LotId = l.Id) lm
    WHERE oty.Code = N'MachiningIn'
    -- FIFO for migrated stock: CastDate (0080) is the real age of inventory
    -- counted in at cutover; NULL on every normally minted LOT, whose arrival
    -- order already IS its FIFO order, so this is inert for existing data.
    ORDER BY COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt) ASC, l.Id ASC;
END;
GO
