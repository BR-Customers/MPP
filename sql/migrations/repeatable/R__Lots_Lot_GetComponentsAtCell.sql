-- ============================================================
-- Repeatable:  R__Lots_Lot_GetComponentsAtCell.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-13
-- Version:     1.2
-- Description: "Components at this cell" read for the assembly screens. Returns the
--              components available to consume at @CellLocationId as the UNION of
--              two legs:
--
--                LEG 1 (routeful) -- open LOTs at the cell whose Item HAS an active
--                  published route, surfaced at their lowest-SequenceNumber PENDING
--                  route step. This is the SAME rule as Lots.Lot_GetWipQueueByLocation
--                  with @OperationTypeCode = NULL (pending per OperationRoleKind:
--                  ConsumeMint always pending while open; Advance pending until a
--                  matching Workorder.ProductionEvent; OriginMint never pending).
--
--                v1.1 (2026-09-12): Leg 1's inline pending-step CTE replaced by
--                Lots.ufn_NextPendingRouteStep. Leg 2 is routeless and untouched.
--
--                v1.2 (2026-11-13, stored-procedure review -- same query SHAPE as the
--                one behind the 2026-11-10 prod incident, notes/2026-11-10_prod-
--                incident-assembly-out-deadlock.md; no deadlock has been observed
--                on THIS proc): same rows, same order, no longer a heap scan.
--                v1.1 OR'd the exact-location and descendant cases in one
--                predicate and aggregated ALL of Lots.LotMovement per call, so it
--                scanned the Lots.Lot heap (a parallel plan, 37 scans / 4,576 reads
--                at prod volume) -- the plan shape that deadlocked
--                Lot_GetWipQueueByLocation v3.2 against Assembly_CompleteTray.
--                Now: locations resolved into @Locs, open LOTs into
--                @AtCell by seek on IX_Lot_NotClosed_Location (0118), last movement
--                by per-LOT seek on CIX_LotMovement_LotMovedAt, and leg 2's
--                eligibility test is evaluated once per distinct Item (it was once
--                per LOT) against ancestors resolved once.
--                Behaviour deliberately UNCHANGED: this proc excludes only Closed
--                (Lot_GetWipQueueByLocation also excludes Open), and a NULL
--                @IncludeDescendants returns nothing, as before.
--
--                LEG 2 (routeless components) -- open LOTs at the cell whose Item has
--                  NO published route AND is BomDerived-eligible here. The
--                  Parts.v_EffectiveItemLocation 'BomDerived' leg means exactly
--                  "eligible at this location BECAUSE the Item is a BOM child of a
--                  part that is Direct-eligible here (the finished good)". So a single
--                  predicate enforces BOTH the eligibility AND the FG-BOM membership
--                  the requirement calls for. Routeless purchased/received components
--                  (which Lot_GetWipQueueByLocation drops on its INNER JOIN to
--                  RouteTemplate) appear here iff they are genuinely a component here.
--
--              The two legs are mutually exclusive (has-route vs no-route), so
--              UNION ALL never double-counts. Result column shape MATCHES
--              Lot_GetWipQueueByLocation so the assembly views' transform is
--              unchanged; leg-2 rows carry NULL NextOperationTypeCode /
--              NextSequenceNumber (no route). ET-converted LastMovementAt (OI-36).
--              Ordered by arrival (FIFO). MAXRECURSION 8.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetComponentsAtCell
    @CellLocationId     BIGINT,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. The locations in scope: the cell alone (@IncludeDescendants = 0) or it and
    --    every descendant (= 1). NULL @IncludeDescendants matches neither -- the v1.1
    --    predicate was NULL for both arms -- so @Locs stays empty and nothing returns.
    DECLARE @Locs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    IF @IncludeDescendants = 1
    BEGIN
        ;WITH Descendants AS (
            SELECT @CellLocationId AS Id
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        INSERT INTO @Locs (Id) SELECT Id FROM Descendants WHERE Id IS NOT NULL
        OPTION (MAXRECURSION 8);
    END
    ELSE IF @IncludeDescendants = 0
        INSERT INTO @Locs (Id) SELECT @CellLocationId WHERE @CellLocationId IS NOT NULL;

    -- 2. Open LOTs physically in scope. Closed is the only status excluded here (v1.1
    --    behaviour). 'LotStatusId <> 4' repeats IX_Lot_NotClosed_Location's filter
    --    (0118) so the optimiser seeks it; the code-table join is what actually decides.
    --    Every column the result needs is read HERE, once per LOT (LOT header, Item, and
    --    the last movement by per-LOT seek on CIX_LotMovement_LotMovedAt -- v1.1
    --    aggregated the whole LotMovement table), so neither leg below re-visits the
    --    Lots.Lot heap or repeats the movement seek.
    DECLARE @AtCell TABLE (LotId BIGINT NOT NULL PRIMARY KEY, ItemId BIGINT NOT NULL,
                           LotName NVARCHAR(50) NOT NULL, PieceCount INT NOT NULL,
                           LotStatusId BIGINT NOT NULL, LotStatusCode NVARCHAR(20) NOT NULL,
                           CastDate DATE NULL,
                           ItemPartNumber NVARCHAR(50) NOT NULL, ItemDescription NVARCHAR(500) NULL,
                           LastMovementAtUtc DATETIME2(3) NULL);
    INSERT INTO @AtCell (LotId, ItemId, LotName, PieceCount, LotStatusId, LotStatusCode, CastDate,
                         ItemPartNumber, ItemDescription, LastMovementAtUtc)
    SELECT l.Id, l.ItemId, l.LotName, l.PieceCount, l.LotStatusId, sc.Code, l.CastDate,
           i.PartNumber, i.Description, lm.LastMovementAt
    FROM @Locs x
    INNER JOIN Lots.Lot l            ON l.CurrentLocationId = x.Id
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
    INNER JOIN Parts.Item i          ON i.Id = l.ItemId
    OUTER APPLY (SELECT MAX(m.MovedAt) AS LastMovementAt
                 FROM Lots.LotMovement m WHERE m.LotId = l.Id) lm
    WHERE l.LotStatusId <> 4;

    -- 3. Leg 2 eligibility, decided once per distinct Item instead of once per LOT:
    --    no published route AND BomDerived-eligible at the cell or an ancestor.
    DECLARE @Anc TABLE (LocationId BIGINT NOT NULL PRIMARY KEY);
    INSERT INTO @Anc (LocationId)
    SELECT LocationId FROM Location.ufn_AncestorLocationIds(@CellLocationId);

    DECLARE @RoutelessItems TABLE (ItemId BIGINT NOT NULL PRIMARY KEY);
    INSERT INTO @RoutelessItems (ItemId)
    SELECT it.ItemId
    FROM (SELECT DISTINCT ItemId FROM @AtCell) it
    WHERE NOT EXISTS (
              SELECT 1 FROM Parts.RouteTemplate rt
              WHERE rt.ItemId = it.ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL)
      AND EXISTS (
              SELECT 1 FROM Parts.v_EffectiveItemLocation e
              WHERE e.ItemId = it.ItemId
                AND e.Source = N'BomDerived'
                AND e.LocationId IN (SELECT LocationId FROM @Anc));

    -- Both legs are wrapped in a derived table so they can share one FIFO
    -- ordering expression (the UNION's single trailing ORDER BY can only see
    -- output columns). FifoAt is projected here and dropped by the outer SELECT,
    -- so the public column shape stays identical to Lot_GetWipQueueByLocation.
    SELECT Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount,
           LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber
    FROM (
    -- Leg 1 result rows
    SELECT
        ac.LotId AS Id, ac.LotName, ac.ItemId,
        ac.ItemPartNumber,
        ac.ItemDescription,
        ac.PieceCount, ac.LotStatusId, ac.LotStatusCode,
        CAST(ac.LastMovementAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        oty.Code          AS NextOperationTypeCode,
        ns.SequenceNumber AS NextSequenceNumber,
        COALESCE(CAST(ac.CastDate AS DATETIME2(3)), ac.LastMovementAtUtc) AS FifoAt
    -- Leg 1: routeful -- lowest-SequenceNumber PENDING route step, via the one
    -- shared definition. @AtCell already carries the status + location filter.
    FROM @AtCell ac
    CROSS APPLY Lots.ufn_NextPendingRouteStep(ac.LotId) ns
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = ns.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId

    UNION ALL

    -- Leg 2: routeless components that are BomDerived-eligible here (eligible + in the FG's BOM).
    SELECT
        ac.LotId AS Id, ac.LotName, ac.ItemId,
        ac.ItemPartNumber,
        ac.ItemDescription,
        ac.PieceCount, ac.LotStatusId, ac.LotStatusCode,
        CAST(ac.LastMovementAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        CAST(NULL AS NVARCHAR(30)) AS NextOperationTypeCode,
        CAST(NULL AS INT)          AS NextSequenceNumber,
        COALESCE(CAST(ac.CastDate AS DATETIME2(3)), ac.LastMovementAtUtc) AS FifoAt
    FROM @AtCell ac
    INNER JOIN @RoutelessItems r     ON r.ItemId = ac.ItemId

    ) u
    -- FIFO for migrated stock: CastDate (0080) is the real age of inventory
    -- counted in at cutover; NULL on every normally minted LOT, whose arrival
    -- order already IS its FIFO order, so this is inert for existing data.
    ORDER BY u.FifoAt ASC, u.Id ASC;
END;
GO
