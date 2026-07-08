-- ============================================================
-- Repeatable:  R__Lots_Lot_GetWipQueueByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     2.0
-- Description: Arc 2 Phase 4 (spec sec 4.1). The FIFO WIP queue at a location:
--              OPEN LOTs (LotStatusCode <> 'Closed') whose CurrentLocationId =
--              @LocationId (or a descendant of it when @IncludeDescendants=1), in
--              ARRIVAL order -- ordered by the LOT's latest LotMovement.MovedAt
--              ASC (Lot carries no denormalized LastMovementAt). Consumed by
--              Phase 5 Machining IN (FIFO pick) + the Assembly / Machining-OUT /
--              Trim screens. Read proc; empty rowset = no WIP.
--
--              v2.0 (2026-07-06): add HasLineEvent -- whether the LOT already has a
--              Workorder.ProductionEvent stamped to a terminal AT/UNDER @LocationId
--              (the line's terminal subtree). Machining IN lists "unworked arrivals"
--              = LOTs at the line with HasLineEvent=0 (the Trim OUT checkpoint is
--              stamped to the TRIM terminal, so it does not count; a Machining IN
--              pick stamps to the line's terminal, so a picked LOT flips to 1 and
--              leaves the queue). Additive: HasRenameBom + all prior columns and the
--              @IncludeDescendants LOT-inclusion semantics are unchanged, so the
--              other callers (Assembly, Machining OUT, Trim, PLC) are unaffected.
--              The line's terminal subtree is walked ALWAYS (independent of
--              @IncludeDescendants, which still governs only LOT inclusion).
--              MAXRECURSION 8.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetWipQueueByLocation
    @LocationId         BIGINT,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- @LocationId + its full descendant subtree. Used two ways: (a) the LOT-
    -- inclusion filter, but ONLY when @IncludeDescendants=1; (b) the HasLineEvent
    -- terminal-attribution check, ALWAYS.
    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
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
        ) THEN 1 ELSE 0 END AS BIT) AS HasRenameBom,
        CAST(CASE WHEN EXISTS (
            SELECT 1 FROM Workorder.ProductionEvent pe
            WHERE pe.LotId = l.Id
              AND pe.TerminalLocationId IN (SELECT Id FROM Descendants)
        ) THEN 1 ELSE 0 END AS BIT) AS HasLineEvent
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    LEFT  JOIN LastMove lm           ON lm.LotId = l.Id
    WHERE (
              (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
           OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @LocationId)
          )
      AND sc.Code <> N'Closed'
    ORDER BY lm.LastMovementAt ASC, l.Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
