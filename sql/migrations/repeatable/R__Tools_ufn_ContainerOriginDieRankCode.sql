-- ============================================================
-- Repeatable: R__Tools_ufn_ContainerOriginDieRankCode.sql
-- Author:     Blue Ridge Automation
-- Version:    1.2 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - Review M7: the representative tray is the first one with its own LOT or its own non-repack draws.
-- Version:    1.1 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - 7.3: new-shape containers resolve the die rank from the FIRST tray's own ConsumptionEvent sources (the container LOT spans every tray); old / mixed containers unchanged.
-- Version:    1.0
-- Description: Brief D -- resolve the "D/C PART LEVEL" (die rank) for a container's
--   shipping label by genealogy trace. DieRankId lives on Tools.Tool (the die), not
--   on any LOT/Container/Item, so we trace:
--
--     Container (@ContainerId)
--       -> Lots.ContainerTray (first CLOSED tray, MIN TrayPosition) .FinishedGoodLotId
--       -> Lots.LotGenealogyClosure ancestors of that FG LOT
--       -> deepest ancestor Lot carrying a ToolId (the die-cast origin)
--       -> Tools.Tool.DieRankId -> Tools.DieRank.Code
--
--   Representative rule (design decision): use the container's FIRST closed tray;
--   die-rank compatibility keeps a production run single-rank. Returns N'' when
--   unresolved (no closed tray / no die-rank ancestor) so the label still prints --
--   genealogy edge cases never block a shipment.
--
--   Set-based (closure table is O(1) per row -- no recursion). Pure read, no side
--   effects, so Lots.ufn_ShippingLabelZpl calls it inside Container_Complete's txn.
-- ============================================================
CREATE OR ALTER FUNCTION Tools.ufn_ContainerOriginDieRankCode (@ContainerId BIGINT)
RETURNS NVARCHAR(20)
AS
BEGIN
    DECLARE @FgLot BIGINT, @FirstTrayId BIGINT, @FirstTrayLot BIGINT;
    -- review M7: the first tray that carries the product's origin -- its own LOT (old
    -- shape) or its own draws (new shape). A repack-move tray has neither and is skipped.
    SELECT TOP 1 @FirstTrayId = t.Id, @FirstTrayLot = t.FinishedGoodLotId
    FROM Lots.ContainerTray t
    WHERE t.ContainerId = @ContainerId
      AND t.ClosedAt IS NOT NULL
      AND (t.FinishedGoodLotId IS NOT NULL
           OR EXISTS (SELECT 1 FROM Workorder.ConsumptionEvent ce
                      WHERE ce.TrayId = t.Id AND ce.ProducedContainerId = @ContainerId
                        -- a draw from another container's finished-good LOT is a repack move
                        AND NOT EXISTS (SELECT 1 FROM Lots.ufn_LotContainers(ce.SourceLotId) lc)))
    ORDER BY t.TrayPosition;

    DECLARE @Code NVARCHAR(20);

    IF @FirstTrayLot IS NOT NULL
    BEGIN
        -- OLD shape (tray = LOT, and a mixed container's first tray): unchanged.
        SELECT TOP 1 @Code = dr.Code
        FROM Lots.LotGenealogyClosure c
        INNER JOIN Lots.Lot      l  ON l.Id  = c.AncestorLotId
        INNER JOIN Tools.Tool    tl ON tl.Id = l.ToolId
        INNER JOIN Tools.DieRank dr ON dr.Id = tl.DieRankId
        WHERE c.DescendantLotId = @FirstTrayLot
          AND l.ToolId IS NOT NULL
        ORDER BY c.Depth DESC;   -- deepest ancestor = the die-cast origin
    END
    ELSE IF @FirstTrayId IS NOT NULL
    BEGIN
        -- NEW shape (v1.1, container-as-LOT 0119): the container LOT spans every tray, so
        -- walking its closure would pick an arbitrary die among all trays' castings. Keep
        -- the "first tray" representative rule through that tray's own draws: its
        -- ConsumptionEvent source LOTs, then their deepest ancestor carrying a ToolId.
        SELECT TOP 1 @Code = dr.Code
        FROM Workorder.ConsumptionEvent ce
        INNER JOIN Lots.LotGenealogyClosure c ON c.DescendantLotId = ce.SourceLotId
        INNER JOIN Lots.Lot      l  ON l.Id  = c.AncestorLotId
        INNER JOIN Tools.Tool    tl ON tl.Id = l.ToolId
        INNER JOIN Tools.DieRank dr ON dr.Id = tl.DieRankId
        WHERE ce.TrayId = @FirstTrayId
          AND ce.ProducedContainerId = @ContainerId
          AND l.ToolId IS NOT NULL
        ORDER BY c.Depth DESC, ce.Id;
    END

    RETURN ISNULL(@Code, N'');
END;
GO
