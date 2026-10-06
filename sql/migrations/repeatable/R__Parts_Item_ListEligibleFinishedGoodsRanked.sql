-- ============================================================
-- Repeatable:  R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1 (2026-10-06) - a finished good with NO published BOM is now
--              listed too (pass-through repack; Assembly_CompleteTray v1.5). It
--              counts as satisfied (LinesSatisfied = 1) when received-origin stock
--              of that same part is at the line -- the same predicate CompleteTray
--              consumes by. Parts WITH a published BOM rank exactly as before,
--              and ahead of a no-BOM part at equal satisfaction.
-- Version:     1.0 (2026-07-07)
-- Description: Ranked eligible finished goods for the Assembly OUT dropdown
--              (terminal-mint spec decision 6 / §5 B5). Eligible FinishedGood Items
--              at @LocationId (direct/ancestor per v_EffectiveItemLocation) that have
--              an active BOM, ranked by (# BOM lines satisfiable by ready line
--              inventory DESC, earliest satisfying WIP ASC). IsRecommended = 1 on the
--              top row. Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty rowset = none eligible.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_ListEligibleFinishedGoodsRanked
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH Elig AS (
        SELECT DISTINCT i.Id AS ItemId, i.PartNumber, i.Description
        FROM Parts.v_EffectiveItemLocation eil
        JOIN Parts.Item i      ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
        JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
        WHERE eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LocationId))
    ),
    ActiveBom AS (
        SELECT e.ItemId,
               (SELECT TOP 1 b.Id FROM Parts.Bom b WHERE b.ParentItemId = e.ItemId AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL ORDER BY b.VersionNumber DESC) AS BomId
        FROM Elig e
    ),
    LineSat AS (
        SELECT ab.ItemId, bl.ChildItemId, bl.QtyPer,
               ISNULL((SELECT SUM(l.InventoryAvailable) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @LocationId AND sc.Code <> N'Closed'), 0) AS Avail,
               (SELECT MIN(m.MovedAt) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       JOIN Lots.LotMovement m ON m.LotId = l.Id
                       WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @LocationId AND sc.Code <> N'Closed' AND l.InventoryAvailable > 0) AS EarliestReady
        FROM ActiveBom ab JOIN Parts.BomLine bl ON bl.BomId = ab.BomId
        UNION ALL
        -- v1.1 repack: no published BOM -> one pseudo-line, the part itself 1:1, fed
        -- by RECEIVED-origin unblocked stock only (Assembly_CompleteTray v1.5's rule).
        SELECT ab.ItemId, ab.ItemId, CAST(1 AS DECIMAL(18,4)),
               ISNULL((SELECT SUM(l.InventoryAvailable) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
                       WHERE l.ItemId = ab.ItemId AND l.CurrentLocationId = @LocationId
                         AND o.Code IN (N'Received', N'ReceivedOffsite')
                         AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0), 0),
               (SELECT MIN(m.MovedAt) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
                       JOIN Lots.LotMovement m ON m.LotId = l.Id
                       WHERE l.ItemId = ab.ItemId AND l.CurrentLocationId = @LocationId
                         AND o.Code IN (N'Received', N'ReceivedOffsite')
                         AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0 AND l.InventoryAvailable > 0)
        FROM ActiveBom ab WHERE ab.BomId IS NULL
    ),
    Agg AS (
        SELECT ItemId, SUM(CASE WHEN Avail >= QtyPer THEN 1 ELSE 0 END) AS LinesSatisfied, MIN(EarliestReady) AS EarliestReady
        FROM LineSat GROUP BY ItemId
    )
    SELECT e.ItemId AS Id, e.PartNumber, e.Description, ISNULL(a.LinesSatisfied, 0) AS LinesSatisfied,
           -- v1.1: at equal satisfaction a part WITH a BOM ranks ahead of a no-BOM
           -- (repack) part, so listing repack parts never changes which part a
           -- normal assembly line recommends.
           CASE WHEN ROW_NUMBER() OVER (ORDER BY ISNULL(a.LinesSatisfied,0) DESC,
                                                 CASE WHEN ab.BomId IS NULL THEN 1 ELSE 0 END ASC,
                                                 a.EarliestReady ASC, e.PartNumber ASC) = 1 THEN 1 ELSE 0 END AS IsRecommended
    FROM Elig e
    INNER JOIN ActiveBom ab ON ab.ItemId = e.ItemId
    LEFT JOIN Agg a ON a.ItemId = e.ItemId
    ORDER BY ISNULL(a.LinesSatisfied,0) DESC,
             CASE WHEN ab.BomId IS NULL THEN 1 ELSE 0 END ASC,
             a.EarliestReady ASC, e.PartNumber ASC;
END;
GO
