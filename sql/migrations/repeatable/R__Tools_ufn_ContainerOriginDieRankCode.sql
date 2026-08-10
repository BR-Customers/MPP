-- ============================================================
-- Repeatable: R__Tools_ufn_ContainerOriginDieRankCode.sql
-- Author:     Blue Ridge Automation
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
    DECLARE @FgLot BIGINT;
    SELECT TOP 1 @FgLot = t.FinishedGoodLotId
    FROM Lots.ContainerTray t
    WHERE t.ContainerId = @ContainerId
      AND t.ClosedAt IS NOT NULL
      AND t.FinishedGoodLotId IS NOT NULL
    ORDER BY t.TrayPosition;

    IF @FgLot IS NULL
        RETURN N'';

    DECLARE @Code NVARCHAR(20);
    SELECT TOP 1 @Code = dr.Code
    FROM Lots.LotGenealogyClosure c
    INNER JOIN Lots.Lot      l  ON l.Id  = c.AncestorLotId
    INNER JOIN Tools.Tool    tl ON tl.Id = l.ToolId
    INNER JOIN Tools.DieRank dr ON dr.Id = tl.DieRankId
    WHERE c.DescendantLotId = @FgLot
      AND l.ToolId IS NOT NULL
    ORDER BY c.Depth DESC;   -- deepest ancestor = the die-cast origin

    RETURN ISNULL(@Code, N'');
END;
GO
