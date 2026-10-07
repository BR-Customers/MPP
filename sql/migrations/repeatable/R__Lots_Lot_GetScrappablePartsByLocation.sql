-- ============================================================
-- Repeatable:  R__Lots_Lot_GetScrappablePartsByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-06
-- Version:     1.0
-- Description: The part list for the Scrap Entry popup (Assembly + Machining
--              terminals). One row per part that has scrappable stock at
--              @LocationId: the part, the total pieces that can be scrapped,
--              and how many LOTs hold them. Read proc; empty rowset = nothing
--              to scrap.
--
--              "Scrappable stock" is the SAME predicate
--              Workorder.RejectEvent_RecordByPartFifo walks -- the two procs
--              MUST change together, or the popup offers a quantity the
--              mutation then refuses:
--                * Lot.CurrentLocationId = @LocationId
--                * LotStatusCode = 'Good' (a held LOT is not scrapped FIFO;
--                  it goes through Hold Management)
--                * per-LOT quantity = the LESSER of PieceCount and
--                  InventoryAvailable, and > 0. The lesser, because the scrap
--                  decrements both and neither may go below zero.
--
--              Finished goods are deliberately included (Jacques's call
--              2026-09-17: a FinishedGood LOT on hand at Assembly OUT is a
--              legitimate scrap target).
--
--              Ordered Description ASC, PartNumber ASC -- the same grouping
--              order as Lots.Lot_GetLineInventoryByPart.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetScrappablePartsByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    SELECT
        l.ItemId,
        i.PartNumber,
        i.Description,
        SUM(CASE WHEN l.PieceCount < l.InventoryAvailable
                 THEN l.PieceCount ELSE l.InventoryAvailable END) AS QuantityAvailable,
        COUNT(*)                                                  AS LotCount
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    WHERE l.CurrentLocationId = @LocationId
      AND sc.Code = N'Good'
      AND l.PieceCount > 0
      AND l.InventoryAvailable > 0
    GROUP BY l.ItemId, i.PartNumber, i.Description
    ORDER BY ISNULL(i.Description, i.PartNumber) ASC,
             i.PartNumber ASC;
END;
GO
