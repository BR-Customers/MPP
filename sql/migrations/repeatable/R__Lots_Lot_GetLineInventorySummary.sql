-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventorySummary.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     2.0
-- Description: The M&A Line Inventory sidebar's single read (spec revision 2,
--              docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md).
--              One row per part.
--
--              LINE. @LocationId (the terminal's session cell) resolves up to its
--              WorkCenter ancestor (LocationTypeId 4, as Terminal_ListByLineOf).
--
--              MEMBERSHIP. Parts with an active IsConsumptionPoint = 1 ItemLocation
--              row at the line or any ancestor (listed even at 0 on hand), plus every
--              other part with available stock at the line. FinishedGood never.
--
--              AVAILABLE. SUM(InventoryAvailable) over LOTs at the line or any
--              descendant with InventoryAvailable > 0 whose status has
--              BlocksProduction = 0 and is not Closed or Open. A held LOT is not
--              available (Jacques, 2026-09-17).
--
--              MAX. The MaxQuantity of the NEAREST consumption row walking up from the
--              line (Depth ASC) -- the same resolution as Lots.Lot_Create 6b, whose cap
--              this value also is. ItemLocationId names that row so the Tolerances
--              popup edits the row the colour came from.
--
--              LEVEL. Integer maths, no rounding: Critical when Available*10 <= Max,
--              Low when Available*10 <= Max*3, else Ok; None when Max is NULL or <= 0.
--
--              SCOPE. @TerminalRole MachiningIn/MachiningOut -> Component ('Castings');
--              AssemblyIn/AssemblyOut -> PassThrough ('Purchased'); NULL, unknown or
--              @LineWide = 1 -> no filter ('All'). ScopeCode is repeated on every row so
--              the proc keeps ONE result set.
--
--              ORDER. Positive Max first by Available/Max ascending (most urgent on
--              top), then no-Max parts; ties and the no-Max group by Description,
--              then ItemId.
--
--              ADD-LOT MODE. PassThrough + BoxQuantity -> OneTap; PassThrough without
--              -> AskQty; otherwise None.
--
--              FDS-11-011: no OUTPUT params; empty set = nothing to show.
--
-- Change Log:
--   2026-09-17 - 1.0 - BOM rollup x finished-good horizon (spec revision 1).
--   2026-09-17 - 1.1 - Held (BlocksProduction) LOTs excluded from Available.
--   2026-09-17 - 2.0 - Spec revision 2: consumption eligibility + % of Max; terminal
--                      scope + line-wide; BOM / running-FG logic and the
--                      @FinishedGoodItemId parameter removed.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineInventorySummary
    @LocationId   BIGINT,
    @TerminalRole NVARCHAR(30) = NULL,
    @LineWide     BIT          = 0
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

    -- scope: role -> item type (NULL = no filter)
    DECLARE @ScopeTypeCode NVARCHAR(30) =
        CASE WHEN ISNULL(@LineWide, 0) = 1 THEN NULL
             WHEN @TerminalRole IN (N'MachiningIn', N'MachiningOut') THEN N'Component'
             WHEN @TerminalRole IN (N'AssemblyIn', N'AssemblyOut')   THEN N'PassThrough'
             ELSE NULL END;
    DECLARE @ScopeTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = @ScopeTypeCode);
    DECLARE @ScopeCode NVARCHAR(20) =
        CASE @ScopeTypeCode WHEN N'Component' THEN N'Castings'
                            WHEN N'PassThrough' THEN N'Purchased'
                            ELSE N'All' END;

    -- 1. the line and everything under it
    DECLARE @LineLocs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    WITH Descendants AS (
        SELECT @LineId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    INSERT INTO @LineLocs (Id) SELECT Id FROM Descendants;

    -- 2. the line and its ancestors, with depth (nearest = 0)
    DECLARE @Chain TABLE (Id BIGINT NOT NULL PRIMARY KEY, Depth INT NOT NULL);
    WITH Up AS (
        SELECT l.Id, l.ParentLocationId, 0 AS Depth FROM Location.Location l WHERE l.Id = @LineId
        UNION ALL
        SELECT p.Id, p.ParentLocationId, u.Depth + 1
        FROM Location.Location p INNER JOIN Up u ON u.ParentLocationId = p.Id
    )
    INSERT INTO @Chain (Id, Depth) SELECT Id, Depth FROM Up;

    -- 3. nearest consumption row per part
    DECLARE @Consume TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, ItemLocationId BIGINT NOT NULL, MaxQuantity INT NULL);
    INSERT INTO @Consume (ItemId, ItemLocationId, MaxQuantity)
    SELECT x.ItemId, x.Id, x.MaxQuantity
    FROM (
        SELECT il.ItemId, il.Id, il.MaxQuantity,
               ROW_NUMBER() OVER (PARTITION BY il.ItemId ORDER BY c.Depth ASC, il.Id ASC) AS rn
        FROM Parts.ItemLocation il
        INNER JOIN @Chain c ON c.Id = il.LocationId
        WHERE il.IsConsumptionPoint = 1 AND il.DeprecatedAt IS NULL
    ) x
    WHERE x.rn = 1;

    -- 4. available at the line (held / blocking / closed / open excluded)
    DECLARE @OnHand TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Available INT NOT NULL);
    INSERT INTO @OnHand (ItemId, Available)
    SELECT l.ItemId, SUM(l.InventoryAvailable)
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CurrentLocationId IN (SELECT Id FROM @LineLocs)
      AND l.InventoryAvailable > 0
      AND sc.BlocksProduction = 0
      AND sc.Code NOT IN (N'Closed', N'Open')
    GROUP BY l.ItemId;

    -- 5. rows
    SELECT
        i.Id                                   AS ItemId,
        ISNULL(i.Description, i.PartNumber)    AS Description,
        ISNULL(oh.Available, 0)                AS Available,
        cp.MaxQuantity                         AS MaxQuantity,
        CAST(CASE WHEN cp.MaxQuantity IS NULL OR cp.MaxQuantity <= 0 THEN N'None'
                  WHEN ISNULL(oh.Available, 0) * 10 <= cp.MaxQuantity     THEN N'Critical'
                  WHEN ISNULL(oh.Available, 0) * 10 <= cp.MaxQuantity * 3 THEN N'Low'
                  ELSE N'Ok' END AS NVARCHAR(10)) AS Level,
        i.BoxQuantity                          AS BoxQuantity,
        CAST(CASE WHEN i.ItemTypeId <> @PassThroughTypeId THEN N'None'
                  WHEN i.BoxQuantity IS NOT NULL THEN N'OneTap'
                  ELSE N'AskQty' END AS NVARCHAR(10)) AS AddLotMode,
        cp.ItemLocationId                      AS ItemLocationId,
        @ScopeCode                             AS ScopeCode
    FROM Parts.Item i
    LEFT JOIN @OnHand  oh ON oh.ItemId = i.Id
    LEFT JOIN @Consume cp ON cp.ItemId = i.Id
    WHERE (oh.ItemId IS NOT NULL OR cp.ItemId IS NOT NULL)
      AND i.ItemTypeId <> @FgTypeId
      AND (@ScopeTypeId IS NULL OR i.ItemTypeId = @ScopeTypeId)
    ORDER BY
        CASE WHEN cp.MaxQuantity > 0 THEN 0 ELSE 1 END,
        CASE WHEN cp.MaxQuantity > 0
             THEN CAST(ISNULL(oh.Available, 0) AS DECIMAL(18,6)) / cp.MaxQuantity END,
        ISNULL(i.Description, i.PartNumber),
        i.Id;
END;
GO
