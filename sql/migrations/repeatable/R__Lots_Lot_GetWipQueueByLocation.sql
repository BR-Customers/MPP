-- ============================================================
-- Repeatable:  R__Lots_Lot_GetWipQueueByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-07
-- Version:     3.0
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
--              v3.0 (2026-07-07): REPLACES the v2.0 HasRenameBom + HasLineEvent hints
--              with the route-driven rule (rename-BOM thread removed). Result columns:
--              Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount,
--              LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode,
--              NextSequenceNumber. Ordered by arrival (LotMovement.MovedAt) ASC.
--              MAXRECURSION 8.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetWipQueueByLocation
    @LocationId         BIGINT,
    @OperationTypeCode  NVARCHAR(20) = NULL,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS LastMovementAt FROM Lots.LotMovement m GROUP BY m.LotId
    ),
    -- Each open LOT at the location joined to the PENDING steps of its active
    -- (published, non-deprecated) route; rank by SequenceNumber to find the next one.
    NextStep AS (
        SELECT l.Id AS LotId, rs.SequenceNumber, rs.OperationTemplateId,
               ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY rs.SequenceNumber ASC) AS rn
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
        INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = l.ItemId
             AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = rs.OperationTemplateId
        INNER JOIN Parts.OperationType oty2    ON oty2.Id = ot2.OperationTypeId
        INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty2.OperationRoleKindId
        WHERE (
                  (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
               OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @LocationId)
              )
          AND (
                  rk.Code = N'ConsumeMint'                       -- terminal: pending while open
               OR (rk.Code = N'Advance' AND NOT EXISTS (
                      SELECT 1 FROM Workorder.ProductionEvent pe
                      WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
                  -- OriginMint: never pending (omitted)
              )
    )
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.LotStatusId, sc.Code AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        oty.Code AS NextOperationTypeCode,
        ns.SequenceNumber AS NextSequenceNumber
    FROM NextStep ns
    INNER JOIN Lots.Lot l               ON l.Id = ns.LotId AND ns.rn = 1
    INNER JOIN Lots.LotStatusCode sc    ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i             ON i.Id  = l.ItemId
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = ns.OperationTemplateId
    INNER JOIN Parts.OperationType oty  ON oty.Id = ot.OperationTypeId
    LEFT  JOIN LastMove lm              ON lm.LotId = l.Id
    WHERE (@OperationTypeCode IS NULL OR oty.Code = @OperationTypeCode)
    ORDER BY lm.LastMovementAt ASC, l.Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
