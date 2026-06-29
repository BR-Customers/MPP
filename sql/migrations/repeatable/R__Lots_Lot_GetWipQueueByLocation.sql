-- ============================================================
-- Repeatable:  R__Lots_Lot_GetWipQueueByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (spec sec 4.1). The FIFO WIP queue at a location:
--              OPEN LOTs (LotStatusCode <> 'Closed') whose CurrentLocationId =
--              @LocationId (or a descendant of it when @IncludeDescendants=1), in
--              ARRIVAL order -- ordered by the LOT's latest LotMovement.MovedAt
--              ASC (Lot carries no denormalized LastMovementAt). Consumed by
--              Phase 5 Machining IN (FIFO pick). Read proc; empty rowset = no WIP.
--              Descendant rollup walks Location.Location.ParentLocationId
--              (MAXRECURSION 8).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetWipQueueByLocation
    @LocationId         BIGINT,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Scope AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Scope s ON c.ParentLocationId = s.Id
        WHERE @IncludeDescendants = 1
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS LastMovementAt
        FROM Lots.LotMovement m
        GROUP BY m.LotId
    )
    SELECT
        l.Id,
        l.LotName,
        l.ItemId,
        i.PartNumber       AS ItemPartNumber,
        i.Description      AS ItemDescription,
        l.PieceCount,
        l.LotStatusId,
        sc.Code            AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        CAST(CASE WHEN EXISTS (
            SELECT 1 FROM Parts.Bom b
            INNER JOIN Parts.BomLine bl ON bl.BomId = b.Id
            WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
              AND bl.ChildItemId = l.ItemId AND bl.QtyPer = 1
              AND NOT EXISTS (SELECT 1 FROM Parts.BomLine x WHERE x.BomId = b.Id AND x.ChildItemId <> l.ItemId)
        ) THEN 1 ELSE 0 END AS BIT) AS HasRenameBom
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    LEFT  JOIN LastMove lm           ON lm.LotId = l.Id
    WHERE l.CurrentLocationId IN (SELECT Id FROM Scope)
      AND sc.Code <> N'Closed'
    ORDER BY lm.LastMovementAt ASC, l.Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
