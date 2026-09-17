-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventoryByPart.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-17
-- Version:     1.3
-- Description: On-hand inventory at a location, grouped by part then FIFO by
--              arrival. Returns OPEN on-hand LOTs (LotStatusCode <> 'Closed' AND
--              InventoryAvailable > 0) whose CurrentLocationId = @LocationId, one
--              row per LOT. ArrivedAt is the LOT's latest LotMovement.MovedAt into
--              @LocationId (falling back to Lot.CreatedAt when the LOT never moved
--              in), ET-converted at the read boundary. Ordered Description ASC,
--              PartNumber ASC, ArrivedAt ASC, LotId ASC so callers see parts grouped
--              alphabetically by description and FIFO within each part. Read proc;
--              empty rowset = nothing on hand.
--
--              v1.3 (2026-09-17): added @ExcludeFinishedGoods BIT = 0 (LAST param,
--              default 0 = pre-c35351d3 behaviour, everything on hand returned).
--              c35351d3 made the FinishedGood exclusion unconditional, which broke
--              the Scrap Entry popup dropdown (BlueRidge.Lots.Lot.getLineInventoryByPart,
--              opened from all four M&A terminals -- AssemblySerialized,
--              AssemblyNonSerialized, MachiningIn, MachiningOutSplit): a FinishedGood
--              LOT minted and sitting on-hand at Assembly OUT could no longer be
--              selected to record scrap against, with no explanation to the operator.
--              Jacques's call (2026-09-17): keep the filter opt-in -- the Line
--              Inventory popup display (getLineInventoryCards) passes 1, Scrap Entry
--              passes nothing and keeps seeing finished goods. Column shape unchanged.
--
--              v1.2 (2026-09-17): FinishedGood items excluded and ordering by
--              Description first, for the Line Inventory popup grouping; column
--              shape unchanged.
--
--              v1.1 (2026-08-20): projects sc.Code AS LotStatusCode. sc was already
--              joined for the WHERE filter but never SELECTed, so every caller's
--              LotStatusCode came back NULL -- BlueRidge.Lots.Lot.getLineInventoryCards
--              (InventoryManager popup) fell back to "", and Trim/InventoryRow's
--              StatusPill treats anything that is not literally 'Good' as Hold. Net
--              effect: every on-hand card in the popup showed a Hold pill regardless
--              of actual status. Callers using a fixed-shape INSERT-EXEC capture must
--              widen to 8 columns.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineInventoryByPart
    @LocationId           BIGINT,
    @ExcludeFinishedGoods BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    ;WITH LastArrival AS (
        SELECT m.LotId, MAX(m.MovedAt) AS ArrivedAtUtc
        FROM Lots.LotMovement m
        WHERE m.ToLocationId = @LocationId
        GROUP BY m.LotId
    )
    SELECT
        l.ItemId,
        i.PartNumber,
        i.Description,
        l.Id                 AS LotId,
        l.LotName,
        l.InventoryAvailable,
        CAST(COALESCE(la.ArrivedAtUtc, l.CreatedAt)
             AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAt,
        sc.Code               AS LotStatusCode
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    LEFT  JOIN LastArrival la        ON la.LotId = l.Id
    WHERE l.CurrentLocationId = @LocationId
      AND sc.Code <> N'Closed'
      AND l.InventoryAvailable > 0
      AND (@ExcludeFinishedGoods = 0
           OR i.ItemTypeId <> (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'))
    ORDER BY ISNULL(i.Description, i.PartNumber) ASC,
             i.PartNumber ASC,
             COALESCE(la.ArrivedAtUtc, l.CreatedAt) ASC,
             l.Id ASC;
END;
GO
