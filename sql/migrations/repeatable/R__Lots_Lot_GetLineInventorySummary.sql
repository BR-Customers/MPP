-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventorySummary.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.1
-- Change (1.1, 2026-09-17, Jacques's decision): held LOTs must not count as
--              available. The @OnHand pool now requires
--              Lots.LotStatusCode.BlocksProduction = 0 (in addition to
--              excluding Closed/Open) rather than only excluding Closed --
--              so a LOT on Hold (or Scrap, or any future blocking status)
--              no longer inflates a part's Available quantity.
-- Description: The M&A Line Inventory sidebar's single read (spec
--              2026-09-17-line-inventory-sidebar-design.md). One row per part.
--
--              LINE. @LocationId (the terminal's session cell) resolves up to its
--              WorkCenter ancestor -- the same resolution as
--              Location.Terminal_ListByLineOf. The pool is every non-blocking,
--              non-Open, non-Closed LOT (Lots.LotStatusCode.BlocksProduction = 0,
--              code not in Closed/Open, InventoryAvailable > 0) at that WorkCenter
--              or any descendant (line-resident flow) -- a LOT on Hold or Scrap
--              is not available.
--
--              RUNNING FINISHED GOODS. Every FinishedGood with an OPEN
--              Lots.Container anywhere under the line, plus @FinishedGoodItemId
--              (the FG the Assembly OUT screen has selected before a container
--              opens).
--
--              THRESHOLD. For each running FG with a LowInventoryHorizon, walk
--              its active BOM tree (Published, not Deprecated, highest
--              VersionNumber per parent), multiplying QtyPer down the levels and
--              summing a child reached by several paths. Threshold =
--              CEILING(rolled qty x horizon); the larger wins across FGs.
--              IsLow = Threshold IS NOT NULL AND Available < Threshold.
--
--              ROWS. Every non-FG part in a running FG's tree (even at 0 on
--              hand) plus every other non-FG part on hand. FinishedGood items
--              are never returned.
--
--              ADD-LOT MODE. PassThrough with BoxQuantity -> OneTap; PassThrough
--              without -> AskQty; anything else -> None.
--
--              HEADER. RunningFinishedGoods (comma-joined descriptions) and
--              LowInventoryHorizon (the largest running horizon) are repeated on
--              every row so the proc keeps one result set.
--
--              ORDER. IsLow DESC, Description, ItemId.
--
--              FDS-11-011: no OUTPUT params; empty set = nothing to show
--              (NULL location or no WorkCenter ancestor).
--
--              BOM recursion is capped at 10 levels (MPP trees are 2-3 deep);
--              the active-BOM set is materialized first because a recursive CTE
--              member may not contain an aggregate.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineInventorySummary
    @LocationId         BIGINT,
    @FinishedGoodItemId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    DECLARE @LineId BIGINT = (
        SELECT TOP 1 l.Id
        FROM Location.ufn_AncestorLocationIds(@LocationId) a
        INNER JOIN Location.Location l ON l.Id = a.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE ltd.LocationTypeId = 4);   -- WorkCenter tier

    IF @LineId IS NULL
        RETURN;

    DECLARE @FgTypeId          BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
    DECLARE @PassThroughTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
    DECLARE @OpenContainerId   BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Open');

    -- 1. the line and everything under it
    DECLARE @LineLocs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    WITH Descendants AS (
        SELECT @LineId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    INSERT INTO @LineLocs (Id) SELECT Id FROM Descendants;

    -- 2. running finished goods
    DECLARE @Running TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Horizon INT NULL, Description NVARCHAR(500) NULL);
    INSERT INTO @Running (ItemId, Horizon, Description)
    SELECT i.Id, i.LowInventoryHorizon, ISNULL(i.Description, i.PartNumber)
    FROM Parts.Item i
    WHERE i.ItemTypeId = @FgTypeId
      AND (   i.Id = @FinishedGoodItemId
           OR EXISTS (SELECT 1 FROM Lots.Container c
                      WHERE c.ItemId = i.Id
                        AND c.ContainerStatusCodeId = @OpenContainerId
                        AND c.CurrentLocationId IN (SELECT Id FROM @LineLocs)));

    -- 3. active BOM per parent (materialized: no aggregate inside the recursion)
    DECLARE @ActiveBom TABLE (ParentItemId BIGINT NOT NULL PRIMARY KEY, BomId BIGINT NOT NULL);
    INSERT INTO @ActiveBom (ParentItemId, BomId)
    SELECT x.ParentItemId, x.Id
    FROM (
        SELECT b.ParentItemId, b.Id,
               ROW_NUMBER() OVER (PARTITION BY b.ParentItemId ORDER BY b.VersionNumber DESC, b.Id DESC) AS rn
        FROM Parts.Bom b
        WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
    ) x
    WHERE x.rn = 1;

    -- 4. rolled-up requirement per part, largest across running FGs
    DECLARE @Req TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Threshold INT NULL);
    WITH Tree AS (
        SELECT r.ItemId AS RootItemId, bl.ChildItemId,
               CAST(bl.QtyPer AS DECIMAL(18,4)) AS RolledQty, 1 AS Depth
        FROM @Running r
        INNER JOIN @ActiveBom ab   ON ab.ParentItemId = r.ItemId
        INNER JOIN Parts.BomLine bl ON bl.BomId = ab.BomId
        UNION ALL
        SELECT t.RootItemId, bl.ChildItemId,
               CAST(t.RolledQty * bl.QtyPer AS DECIMAL(18,4)), t.Depth + 1
        FROM Tree t
        INNER JOIN @ActiveBom ab   ON ab.ParentItemId = t.ChildItemId
        INNER JOIN Parts.BomLine bl ON bl.BomId = ab.BomId
        WHERE t.Depth < 10
    )
    INSERT INTO @Req (ItemId, Threshold)
    SELECT n.ChildItemId,
           MAX(CASE WHEN r.Horizon IS NULL THEN NULL
                    ELSE CAST(CEILING(n.Qty * r.Horizon) AS INT) END)
    FROM (SELECT RootItemId, ChildItemId, SUM(RolledQty) AS Qty
          FROM Tree GROUP BY RootItemId, ChildItemId) n
    INNER JOIN @Running r ON r.ItemId = n.RootItemId
    GROUP BY n.ChildItemId;

    -- 5. on hand at the line
    DECLARE @OnHand TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Available INT NOT NULL);
    INSERT INTO @OnHand (ItemId, Available)
    SELECT l.ItemId, SUM(l.InventoryAvailable)
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CurrentLocationId IN (SELECT Id FROM @LineLocs)
      AND sc.BlocksProduction = 0
      AND sc.Code NOT IN (N'Closed', N'Open')
      AND l.InventoryAvailable > 0
    GROUP BY l.ItemId;

    DECLARE @RunningText NVARCHAR(1000) =
        (SELECT STRING_AGG(Description, N', ') WITHIN GROUP (ORDER BY Description) FROM @Running);
    DECLARE @Horizon INT = (SELECT MAX(Horizon) FROM @Running);

    -- 6. rows
    SELECT
        i.Id                                   AS ItemId,
        ISNULL(i.Description, i.PartNumber)    AS Description,
        ISNULL(oh.Available, 0)                AS Available,
        rq.Threshold                           AS Threshold,
        CAST(CASE WHEN rq.Threshold IS NOT NULL AND ISNULL(oh.Available, 0) < rq.Threshold
                  THEN 1 ELSE 0 END AS BIT)    AS IsLow,
        i.BoxQuantity                          AS BoxQuantity,
        CAST(CASE WHEN i.ItemTypeId <> @PassThroughTypeId THEN N'None'
                  WHEN i.BoxQuantity IS NOT NULL THEN N'OneTap'
                  ELSE N'AskQty' END AS NVARCHAR(10)) AS AddLotMode,
        @RunningText                           AS RunningFinishedGoods,
        @Horizon                               AS LowInventoryHorizon
    FROM Parts.Item i
    LEFT JOIN @OnHand oh ON oh.ItemId = i.Id
    LEFT JOIN @Req    rq ON rq.ItemId = i.Id
    WHERE (oh.ItemId IS NOT NULL OR rq.ItemId IS NOT NULL)
      AND i.ItemTypeId <> @FgTypeId
    ORDER BY IsLow DESC, Description ASC, i.Id ASC;
END;
GO
