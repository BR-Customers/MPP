-- ============================================================
-- Repeatable:  R__Lots_Lot_GetWipQueueByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-10
-- Version:     3.3
-- Description: Terminal-mint model (spec 2026-07-07 §3.2). ROUTE-DRIVEN WIP queue:
--              for a given terminal role @OperationTypeCode, returns the OPEN
--              (LotStatusCode <> 'Closed') LOTs at @LocationId (or a descendant when
--              @IncludeDescendants=1) whose NEXT PENDING route step carries that role.
--              "Pending" depends on the step's OperationRoleKind:
--                * Advance     -> pending until a matching Workorder.ProductionEvent
--                                 exists for the LOT on that step's OperationTemplateId.
--                * OriginMint  -> never pending (the LOT exists => it was minted there).
--                * ConsumeMint -> always pending while the LOT is open; it is the
--                                 terminal step and the LOT leaves the queue only by
--                                 closing (fully consumed). This keeps a decrementing
--                                 casting in the Machining OUT queue across repeated
--                                 partial mints.
--              When @OperationTypeCode IS NULL, returns every open LOT at the location
--              with its resolved next-step role (inventory/debug read).
--
--              v3.3 (2026-11-10, prod incident -- notes/2026-11-10_prod-incident-
--              assembly-out-deadlock.md): same rows, same order, no longer a heap
--              scan. v3.2 OR'd the exact-location and descendant cases in one
--              predicate and aggregated ALL of Lots.LotMovement per call, so it
--              scanned the Lots.Lot heap with page locks, went parallel, and
--              deadlocked undetectably against Workorder.Assembly_CompleteTray.
--              Now: locations resolved into @Locs, open LOTs into @Lots by seek on
--              IX_Lot_NotClosed_Location (0118), last movement by per-LOT seek.
--
--              v3.2 (2026-09-12): the inline pending-step CTE is replaced by
--              Lots.ufn_NextPendingRouteStep (one definition, formerly copy-pasted
--              seven times across five procs). Status + location filtering stays
--              in this proc -- it excludes Closed AND Open where siblings exclude
--              only Closed -- so the extraction is behaviour-neutral.
--
--              v3.0 (2026-07-07): REPLACES the v2.0 HasRenameBom + HasLineEvent hints
--              with the route-driven rule (rename-BOM thread removed). Result columns:
--              Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount,
--              LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode,
--              NextSequenceNumber. Ordered by arrival (LotMovement.MovedAt) ASC.
--              MAXRECURSION 8.
--
--   PARAM  @IncludeDescendants  0 = match only LOTs whose CurrentLocationId is
--              EXACTLY @LocationId; 1 = also match LOTs residing in ANY descendant
--              location. Choose it by how the caller's terminal zone maps to where
--              LOTs physically reside -- it is NOT "always 1":
--                * Trim Check IN / Trim OUT pass 0. Under the current model a LOT in
--                  trim resides AT the trim shop (the Area) itself -- never down in a
--                  Press or Trim Storage child cell. Trim Storage is a child Cell of
--                  the shop that holds LOTs which have ALREADY trimmed out and are
--                  staged for Machining IN (next step MachiningIn); passing 1 would
--                  wrongly pull those post-trim LOTs back into the trim work lists
--                  (2026-08-03 -- the symptom that drove this note). 0 scopes the
--                  lists to what is physically at the shop.
--                * Callers whose zone legitimately spans sub-cells (e.g. Machining
--                  reading a line with cells beneath it) pass 1.
--              Prefer the @OperationTypeCode role filter over descendant tricks when
--              the intent is "LOTs pending a specific step" rather than "LOTs here".
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetWipQueueByLocation
    @LocationId         BIGINT,
    @OperationTypeCode  NVARCHAR(20) = NULL,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. The locations in scope: @LocationId alone, or it and every descendant.
    --    Resolved up front (v3.3) so step 2 is a plain seek -- the v3.2 single
    --    statement OR'd the two cases, which no index can serve.
    DECLARE @Locs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    IF @IncludeDescendants = 1
    BEGIN
        ;WITH Descendants AS (
            SELECT @LocationId AS Id
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        INSERT INTO @Locs (Id) SELECT Id FROM Descendants WHERE Id IS NOT NULL
        OPTION (MAXRECURSION 8);
    END
    ELSE
        INSERT INTO @Locs (Id) SELECT @LocationId WHERE @LocationId IS NOT NULL;

    -- 2. Open LOTs physically in scope. Status + location filtering stays HERE:
    --    this proc excludes Closed AND Open, its siblings exclude only Closed, so
    --    the shared pending-step function deliberately does not filter either.
    --    'LotStatusId <> 4' repeats IX_Lot_NotClosed_Location's filter (0118) so the
    --    optimiser seeks it; the code-table join is what actually decides.
    DECLARE @Lots TABLE (LotId BIGINT NOT NULL PRIMARY KEY);
    INSERT INTO @Lots (LotId)
    SELECT l.Id
    FROM @Locs x
    INNER JOIN Lots.Lot l            ON l.CurrentLocationId = x.Id
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code NOT IN (N'Closed', N'Open')
    WHERE l.LotStatusId <> 4;

    -- 3. Each in-scope LOT with its next PENDING route step. LastMovementAt is a
    --    per-LOT seek on CIX_LotMovement_LotMovedAt (v3.3; v3.2 aggregated the
    --    whole LotMovement table on every call).
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
    WHERE (@OperationTypeCode IS NULL OR oty.Code = @OperationTypeCode)
    -- FIFO for migrated stock: CastDate (0080) is the real age of inventory
    -- counted in at cutover; NULL on every normally minted LOT, whose arrival
    -- order already IS its FIFO order, so this is inert for existing data.
    ORDER BY COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt) ASC, l.Id ASC;
END;
GO
