-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventoryByPart.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-13
-- Version:     1.4
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
--              v1.4 (2026-11-13, stored-procedure review -- same query SHAPE as the one
--              behind the 2026-11-10 prod incident, notes/2026-11-10_prod-incident-
--              assembly-out-deadlock.md; no deadlock has been observed on THIS proc):
--              same rows, same order, no longer a heap scan. v1.3 aggregated ALL of
--              Lots.LotMovement (filtered only by ToLocationId, which no index serves)
--              and filtered open LOTs only through the LotStatusCode join, so every call
--              scanned the Lots.LotMovement table and the Lots.Lot heap (748 + 1,424
--              pages at prod volume, parallel). Now: open LOTs at the location are found
--              by seek on IX_Lot_NotClosed_Location (0118; 'LotStatusId <> 4' repeats its
--              filter, the code-table join still decides) and each LOT's latest arrival
--              is a per-LOT seek on CIX_LotMovement_LotMovedAt. The Closed literal is the
--              same one 0118 uses; this proc therefore benefits from, but does not
--              require, 0118 for correctness.
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

    -- FinishedGood item type, resolved once. A NULL here (type missing) keeps the v1.3
    -- behaviour: "ItemTypeId <> NULL" is unknown, so @ExcludeFinishedGoods = 1 returns nothing.
    DECLARE @FgTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');

    -- 1. Open on-hand LOTs at the location, each with its Item and latest arrival INTO the
    --    location (per-LOT seek). 'LotStatusId <> 4' (Closed) repeats the filtered-index
    --    predicate of IX_Lot_NotClosed_Location (0118) so the optimiser can seek it; the
    --    code-table test beside it is what actually decides. Every column the result needs
    --    is read here once, so the final SELECT never re-visits Lots.Lot.
    DECLARE @Lots TABLE (LotId BIGINT NOT NULL PRIMARY KEY, ItemId BIGINT NOT NULL, LotName NVARCHAR(50) NOT NULL,
                         InventoryAvailable INT NOT NULL, CreatedAt DATETIME2(3) NOT NULL, LotStatusCode NVARCHAR(20) NOT NULL,
                         PartNumber NVARCHAR(50) NOT NULL, Description NVARCHAR(500) NULL, ArrivedAtUtc DATETIME2(3) NULL);
    INSERT INTO @Lots (LotId, ItemId, LotName, InventoryAvailable, CreatedAt, LotStatusCode, PartNumber, Description, ArrivedAtUtc)
    SELECT l.Id, l.ItemId, l.LotName, l.InventoryAvailable, l.CreatedAt, sc.Code, i.PartNumber, i.Description, la.ArrivedAtUtc
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    OUTER APPLY (SELECT MAX(m.MovedAt) AS ArrivedAtUtc
                 FROM Lots.LotMovement m
                 WHERE m.LotId = l.Id AND m.ToLocationId = @LocationId) la
    WHERE l.CurrentLocationId = @LocationId
      AND l.LotStatusId <> 4
      AND sc.Code <> N'Closed'
      AND l.InventoryAvailable > 0
      AND (@ExcludeFinishedGoods = 0
           OR i.ItemTypeId <> @FgTypeId);

    -- 2. Result: ET at the read boundary, grouped by part then FIFO by arrival.
    SELECT
        e.ItemId,
        e.PartNumber,
        e.Description,
        e.LotId              AS LotId,
        e.LotName,
        e.InventoryAvailable,
        CAST(COALESCE(e.ArrivedAtUtc, e.CreatedAt)
             AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAt,
        e.LotStatusCode
    FROM @Lots e
    ORDER BY ISNULL(e.Description, e.PartNumber) ASC,
             e.PartNumber ASC,
             COALESCE(e.ArrivedAtUtc, e.CreatedAt) ASC,
             e.LotId ASC;
END;
GO
