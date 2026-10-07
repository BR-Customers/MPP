-- ============================================================
-- Repeatable:  R__Workorder_Assembly_GetTraysRemaining.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Version:     1.0
-- Description: How many more trays of a finished good the line can close before a
--              PURCHASED part runs out -- the read behind the Assembly OUT
--              low-inventory lock
--              (docs/superpowers/specs/2026-10-06-assembly-out-low-inventory-lock-design.md).
--              One row per checked part, shortest first. NOT a gate: the
--              authoritative sufficiency check stays in
--              Workorder.Assembly_CompleteTray.
--
--              PARTS CHECKED.
--                Published BOM  -> each BOM line whose child is PassThrough. A
--                                  casting or sub-assembly is never listed: the
--                                  operator cannot add one from this terminal.
--                No published BOM (pass-through repack, CompleteTray v1.5)
--                               -> the finished good itself.
--
--              PIECES PER TRAY. BOM line: CAST(QtyPer * PartsPerTray AS INT), the
--              same expression CompleteTray consumes by. Repack: PartsPerTray.
--              A line that rounds to 0 is skipped (nothing to divide by).
--
--              AVAILABLE. *** MIRRORS Workorder.Assembly_CompleteTray -- keep in
--              lock-step. *** LOTs of the part with CurrentLocationId = the cell
--              (exact), BlocksProduction = 0, not Closed / Open. Repack adds the
--              Received / ReceivedOffsite origin filter, which is load-bearing
--              there: the tray LOTs CompleteTray mints are the same Item at the
--              same cell, and only their Manufactured origin keeps them out.
--
--              SHORT. TraysLeft = Available / PiecesPerTray (integer division);
--              IsShort = 1 when TraysLeft <= @ThresholdTrays (3, Jacques
--              2026-10-06: "stop when we are 3 trays from an inventory failure").
--
--              FDS-11-011: no OUTPUT params; single result set; empty set = no
--              calc (NULL input / no pack-out for the closure method / NULL
--              PartsPerTray / BOM with no purchased line).
--
-- Change Log:
--   2026-10-06 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.Assembly_GetTraysRemaining
    @CellLocationId     BIGINT,
    @FinishedGoodItemId BIGINT,
    @ClosureMethod      NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @CellLocationId IS NULL OR @FinishedGoodItemId IS NULL
        RETURN;

    DECLARE @ThresholdTrays INT = 3;

    -- pack-out for THIS (Item, closure method) -- same resolution as CompleteTray 4b
    DECLARE @PartsPerTray INT = (
        SELECT cc.PartsPerTray
        FROM Parts.ContainerConfig cc
        WHERE cc.ItemId = @FinishedGoodItemId
          AND cc.ClosureMethod = @ClosureMethod
          AND cc.DeprecatedAt IS NULL);

    IF @PartsPerTray IS NULL OR @PartsPerTray <= 0
        RETURN;

    -- active BOM -- same resolution as CompleteTray 6
    DECLARE @BomId BIGINT = (
        SELECT TOP 1 Id FROM Parts.Bom
        WHERE ParentItemId = @FinishedGoodItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
        ORDER BY VersionNumber DESC);

    DECLARE @PassThroughTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');

    DECLARE @Need TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, PiecesPerTray INT NOT NULL, ReceivedOnly BIT NOT NULL);

    IF @BomId IS NULL
        INSERT INTO @Need (ItemId, PiecesPerTray, ReceivedOnly)
        VALUES (@FinishedGoodItemId, @PartsPerTray, 1);
    ELSE
        INSERT INTO @Need (ItemId, PiecesPerTray, ReceivedOnly)
        SELECT bl.ChildItemId, SUM(CAST(bl.QtyPer * @PartsPerTray AS INT)), 0
        FROM Parts.BomLine bl
        INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId
        WHERE bl.BomId = @BomId
          AND ci.ItemTypeId = @PassThroughTypeId
        GROUP BY bl.ChildItemId
        HAVING SUM(CAST(bl.QtyPer * @PartsPerTray AS INT)) > 0;

    SELECT
        i.Id                                    AS ItemId,
        i.PartNumber                            AS PartNumber,
        ISNULL(i.Description, i.PartNumber)     AS Description,
        i.BoxQuantity                           AS BoxQuantity,
        n.PiecesPerTray                         AS PiecesPerTray,
        s.Available                             AS Available,
        s.Available / n.PiecesPerTray           AS TraysLeft,
        CAST(CASE WHEN s.Available / n.PiecesPerTray <= @ThresholdTrays THEN 1 ELSE 0 END AS BIT) AS IsShort,
        @ThresholdTrays                         AS ThresholdTrays
    FROM @Need n
    INNER JOIN Parts.Item i ON i.Id = n.ItemId
    CROSS APPLY (
        SELECT ISNULL(SUM(l.InventoryAvailable), 0) AS Available
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        INNER JOIN Lots.LotOriginType o  ON o.Id  = l.LotOriginTypeId
        WHERE l.ItemId = n.ItemId
          AND l.CurrentLocationId = @CellLocationId
          AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0
          AND (n.ReceivedOnly = 0 OR o.Code IN (N'Received', N'ReceivedOffsite'))
    ) s
    ORDER BY s.Available / n.PiecesPerTray, ISNULL(i.Description, i.PartNumber), i.Id;
END;
GO
