-- ============================================================
-- Teardown for the press-counter review book fixtures.
--
-- The book (three walked-through die cast shifts) left three dies mounted on
-- what were idle Die Cast 1 machines, so the scenarios can be poked at in the
-- live terminal after the fact:
--
--   RB-A  Machine 04  1 cavity   -- ten 70-piece baskets + a partial at 735
--   RB-B  Machine 05  4 cavities -- two cavities rolled at 1450, closed at 2000
--   RB-C  Machine 06  4 cavities -- solid run, nothing released, closed at 1800
--
-- Run this when you are done looking. It removes ONLY RB-* objects and the
-- LOTs hanging off them; nothing that existed before the review book is
-- touched. Machines 04/05/06 go back to carrying no tool.
--
-- Safe to re-run.
-- ============================================================
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Tools TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Tools SELECT Id FROM Tools.Tool WHERE Code IN (N'RB-A', N'RB-B', N'RB-C');

DECLARE @Lots TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Lots SELECT Id FROM Lots.Lot WHERE ToolId IN (SELECT Id FROM @Tools);

-- LOT-hanging rows first (reverse FK order; closure before the LOTs themselves)
DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId IN (SELECT Id FROM @Tools);
DELETE FROM Workorder.DieCastContribution  WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Lots)
                                        OR DescendantLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Lots)
                                 OR ChildLotId  IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Lots) OR ParentLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Lots);

-- tool side
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM @Tools);
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM @Tools);
DELETE FROM Tools.Tool           WHERE Id IN (SELECT Id FROM @Tools);

-- part side
DECLARE @Items TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Items SELECT Id FROM Parts.Item WHERE PartNumber IN (N'RB-A-70', N'RB-B-2200', N'RB-C-2000');

DELETE FROM Parts.RouteStep WHERE RouteTemplateId IN
    (SELECT Id FROM Parts.RouteTemplate WHERE ItemId IN (SELECT Id FROM @Items));
DELETE FROM Parts.RouteTemplate WHERE ItemId IN (SELECT Id FROM @Items);
DELETE FROM Parts.ItemLocation  WHERE ItemId IN (SELECT Id FROM @Items);
DELETE FROM Parts.Item          WHERE Id IN (SELECT Id FROM @Items);

PRINT 'Review-book fixtures removed. Machines 04/05/06 are idle again.';

SELECT l.Code, l.Name, ISNULL(t.Code, N'(none)') AS MountedDie
FROM Location.Location l
LEFT JOIN Tools.ToolAssignment a ON a.CellLocationId = l.Id AND a.ReleasedAt IS NULL
LEFT JOIN Tools.Tool t ON t.Id = a.ToolId
WHERE l.Code IN (N'DC1-M04', N'DC1-M05', N'DC1-M06')
ORDER BY l.Code;
GO
