-- ============================================================
-- Repeatable:  R__Parts_ItemLocation_ListConsumptionForLine.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.1
-- Description: Read proc behind the Line Inventory "Tolerances" popup (Task R3,
--              docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md).
--              One row per consumption part known to a line, so the popup can list
--              every Min/Max pair an operator might want to open, not just the
--              part the sidebar row was clicked from.
--
--              LINE. @LocationId (the terminal's session cell) resolves up to its
--              WorkCenter ancestor (LocationTypeId 4), same as
--              Lots.Lot_GetLineInventorySummary. Empty set for a NULL location or
--              one with no WorkCenter ancestor.
--
--              MEMBERSHIP. One row per part with an active IsConsumptionPoint = 1
--              Parts.ItemLocation row at the line or any ancestor, nearest row
--              wins (Depth ASC) -- the exact resolution
--              Lots.Lot_GetLineInventorySummary uses for its Max column, and the
--              same one Lots.Lot_Create section 6b uses at check-in time.
--              FinishedGood items are excluded (never a consumption point in
--              practice, excluded defensively to match the sidebar's own rule).
--
--              AVAILABLE. Same definition as Lots.Lot_GetLineInventorySummary:
--              SUM(InventoryAvailable) over LOTs at the line or any descendant,
--              InventoryAvailable > 0, status BlocksProduction = 0 and not
--              Closed/Open.
--
--              The blocks below marked "source of truth:
--              Lots.Lot_GetLineInventorySummary" are copied verbatim from that
--              proc (v2.0) rather than factored into a shared function -- they are
--              table-variable fills local to one proc body, not reusable logic.
--
--              FDS-11-011: no OUTPUT params; one result set; empty set = nothing
--              to show.
--
-- Parameters (input):
--   @LocationId BIGINT   - Any location on/under a line (typically a terminal).
--
-- Result set:
--   ItemLocationId BIGINT, ItemId BIGINT, Description NVARCHAR(500),
--   Available INT, MaxQuantity INT NULL, MinQuantity INT NULL,
--   RowLocationCode NVARCHAR(50), LineLocationCode NVARCHAR(50).
--   Ordered by Description, then ItemId.
--
--   LineLocationCode (v1.1) is the resolved line's (the @LocationId's WorkCenter
--   ancestor) own Code, trailing so it does not disturb the fixed-shape v1.0
--   capture tables. Comparing it to RowLocationCode is how the popup shows
--   "Shared: <code>" when the consumption row that set Max lives on an
--   ancestor Area rather than the line itself -- editing that row changes
--   every line under the area, not just this one.
--
-- Dependencies:
--   Tables: Parts.ItemLocation, Parts.Item, Parts.ItemType, Location.Location,
--           Lots.Lot, Lots.LotStatusCode
--   Funcs:  Location.ufn_AncestorLocationIds
--
-- Change Log:
--   2026-09-17 - 1.1 - Trailing LineLocationCode column (the resolved line's own
--                       Code) so callers can tell a shared/ancestor Max row from
--                       one scoped to this line (Task FINAL-REVIEW-5).
--   2026-09-17 - 1.0 - Initial version (Line Inventory Tolerances popup, Task R3)
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_ListConsumptionForLine
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    -- source of truth: Lots.Lot_GetLineInventorySummary -- line resolution
    DECLARE @LineId BIGINT = (
        SELECT TOP 1 l.Id
        FROM Location.ufn_AncestorLocationIds(@LocationId) a
        INNER JOIN Location.Location l ON l.Id = a.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE ltd.LocationTypeId = 4);   -- WorkCenter tier

    IF @LineId IS NULL
        RETURN;

    DECLARE @LineLocationCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @LineId);
    DECLARE @FgTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');

    -- source of truth: Lots.Lot_GetLineInventorySummary -- 1. the line and everything under it
    DECLARE @LineLocs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    WITH Descendants AS (
        SELECT @LineId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    INSERT INTO @LineLocs (Id) SELECT Id FROM Descendants;

    -- source of truth: Lots.Lot_GetLineInventorySummary -- 2. the line and its ancestors, with depth (nearest = 0)
    DECLARE @Chain TABLE (Id BIGINT NOT NULL PRIMARY KEY, Depth INT NOT NULL);
    WITH Up AS (
        SELECT l.Id, l.ParentLocationId, 0 AS Depth FROM Location.Location l WHERE l.Id = @LineId
        UNION ALL
        SELECT p.Id, p.ParentLocationId, u.Depth + 1
        FROM Location.Location p INNER JOIN Up u ON u.ParentLocationId = p.Id
    )
    INSERT INTO @Chain (Id, Depth) SELECT Id, Depth FROM Up;

    -- source of truth: Lots.Lot_GetLineInventorySummary -- 3. nearest consumption row per part
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

    -- source of truth: Lots.Lot_GetLineInventorySummary -- 4. available at the line (held / blocking / closed / open excluded)
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

    -- 5. rows: nearest consumption row per part, joined back for Min/Max/RowLocationCode
    SELECT
        cp.ItemLocationId                   AS ItemLocationId,
        i.Id                                 AS ItemId,
        ISNULL(i.Description, i.PartNumber)  AS Description,
        ISNULL(oh.Available, 0)              AS Available,
        il.MaxQuantity                       AS MaxQuantity,
        il.MinQuantity                       AS MinQuantity,
        loc.Code                             AS RowLocationCode,
        @LineLocationCode                    AS LineLocationCode
    FROM @Consume cp
    INNER JOIN Parts.Item i           ON i.Id = cp.ItemId
    INNER JOIN Parts.ItemLocation il  ON il.Id = cp.ItemLocationId
    INNER JOIN Location.Location loc  ON loc.Id = il.LocationId
    LEFT JOIN @OnHand oh               ON oh.ItemId = i.Id
    WHERE i.ItemTypeId <> @FgTypeId
    ORDER BY
        ISNULL(i.Description, i.PartNumber),
        i.Id;
END;
GO
