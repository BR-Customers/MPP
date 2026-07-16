-- ============================================================
-- Repeatable:  R__Lots_Lot_GetComponentsAtCell.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
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

    ;WITH Descendants AS (
        SELECT @CellLocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS LastMovementAt FROM Lots.LotMovement m GROUP BY m.LotId
    ),
    -- Open LOTs physically at the cell (or a descendant when @IncludeDescendants = 1).
    AtCell AS (
        SELECT l.Id, l.ItemId
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
        WHERE ( (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
             OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @CellLocationId) )
    ),
    -- Leg 1: routeful -- lowest-SequenceNumber PENDING route step (mirrors Lot_GetWipQueueByLocation v3.0).
    NextStep AS (
        SELECT ac.Id AS LotId, rs.SequenceNumber, rs.OperationTemplateId,
               ROW_NUMBER() OVER (PARTITION BY ac.Id ORDER BY rs.SequenceNumber ASC) AS rn
        FROM AtCell ac
        INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = ac.ItemId
             AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = rs.OperationTemplateId
        INNER JOIN Parts.OperationType oty2    ON oty2.Id = ot2.OperationTypeId
        INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty2.OperationRoleKindId
        WHERE rk.Code = N'ConsumeMint'
           OR (rk.Code = N'Advance' AND NOT EXISTS (
                  SELECT 1 FROM Workorder.ProductionEvent pe
                  WHERE pe.LotId = ac.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
    )
    -- Leg 1 result rows
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.LotStatusId, sc.Code AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        oty.Code          AS NextOperationTypeCode,
        ns.SequenceNumber AS NextSequenceNumber
    FROM NextStep ns
    INNER JOIN Lots.Lot l                 ON l.Id = ns.LotId AND ns.rn = 1
    INNER JOIN Lots.LotStatusCode sc      ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i               ON i.Id  = l.ItemId
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = ns.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    LEFT  JOIN LastMove lm                ON lm.LotId = l.Id

    UNION ALL

    -- Leg 2: routeless components that are BomDerived-eligible here (eligible + in the FG's BOM).
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.LotStatusId, sc.Code AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        CAST(NULL AS NVARCHAR(30)) AS NextOperationTypeCode,
        CAST(NULL AS INT)          AS NextSequenceNumber
    FROM AtCell ac
    INNER JOIN Lots.Lot l            ON l.Id = ac.Id
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    LEFT  JOIN LastMove lm           ON lm.LotId = l.Id
    WHERE NOT EXISTS (
              SELECT 1 FROM Parts.RouteTemplate rt
              WHERE rt.ItemId = l.ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL)
      AND EXISTS (
              SELECT 1 FROM Parts.v_EffectiveItemLocation e
              WHERE e.ItemId = l.ItemId
                AND e.Source = N'BomDerived'
                AND e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@CellLocationId)))

    ORDER BY LastMovementAt ASC, Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
