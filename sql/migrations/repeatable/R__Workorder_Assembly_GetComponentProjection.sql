-- ============================================================
-- Repeatable:  R__Workorder_Assembly_GetComponentProjection.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: DISPLAY-ONLY read for the Assembly OUT line-inventory panel. Per active-BOM
--              component of the finished good, returns how many will be consumed to COMPLETE
--              the current container + a low-stock flag. NOT a gate -- the authoritative
--              sufficiency check lives in Workorder.Assembly_CompleteTray. Co-located here so
--              the BOM x tray consumption math has one home.
--
--              Math mirrors Assembly_CompleteTray exactly (so the display reconciles with the
--              gate): PerTrayNeed = CAST(QtyPer * PartsPerTray AS INT); container target =
--              TraysPerContainer * PartsPerTray; RemainingTrays = MAX(Trays - ClosedTrays, 0);
--              OnHand = exact-cell (CurrentLocationId = @CellLocationId) non-closed
--              InventoryAvailable -- the SAME pool the proc drains, NOT the wider descendants
--              pool the display list uses.
--
--              FDS-11-011: no OUTPUT params; single result set; empty set = nothing to show
--              (FG null / no active BOM / no resolvable ContainerConfig). No status row.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.Assembly_GetComponentProjection
    @CellLocationId     BIGINT,
    @FinishedGoodItemId BIGINT,
    @ClosureMethod      NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @CellLocationId IS NULL OR @FinishedGoodItemId IS NULL
        RETURN;   -- empty set

    DECLARE @TraysPerContainer INT, @PartsPerTray INT, @ClosedTrays INT = 0, @BomId BIGINT;
    DECLARE @OpenCid BIGINT, @CfgId BIGINT;

    -- 1. open container at the cell for this FG? take its geometry + closed-tray count
    SELECT TOP 1 @OpenCid = Id, @CfgId = ContainerConfigId
    FROM Lots.Container
    WHERE CurrentLocationId = @CellLocationId AND ItemId = @FinishedGoodItemId AND ContainerStatusCodeId = 1
    ORDER BY OpenedAt, Id;

    IF @OpenCid IS NOT NULL
    BEGIN
        SELECT @TraysPerContainer = TraysPerContainer, @PartsPerTray = PartsPerTray
        FROM Parts.ContainerConfig WHERE Id = @CfgId;
        SET @ClosedTrays = (SELECT COUNT(*) FROM Lots.ContainerTray WHERE ContainerId = @OpenCid AND ClosedAt IS NOT NULL);
    END
    ELSE
    BEGIN
        -- 2. no open container -> fresh full-container projection via (Item, ClosureMethod) config
        SELECT @TraysPerContainer = TraysPerContainer, @PartsPerTray = PartsPerTray
        FROM Parts.ContainerConfig
        WHERE ItemId = @FinishedGoodItemId AND ClosureMethod = @ClosureMethod AND DeprecatedAt IS NULL;
    END

    IF @TraysPerContainer IS NULL OR @PartsPerTray IS NULL
        RETURN;   -- no resolvable config -> empty set

    -- 3. active BOM
    SET @BomId = (SELECT TOP 1 Id FROM Parts.Bom
        WHERE ParentItemId = @FinishedGoodItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
        ORDER BY VersionNumber DESC);
    IF @BomId IS NULL
        RETURN;   -- empty set

    DECLARE @RemainingTrays INT = CASE WHEN @TraysPerContainer - @ClosedTrays > 0 THEN @TraysPerContainer - @ClosedTrays ELSE 0 END;

    -- 4. one row per BOM component
    SELECT
        bl.ChildItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        bl.QtyPer,
        CAST(bl.QtyPer * @PartsPerTray AS INT)                    AS PerTrayNeed,
        @RemainingTrays                                           AS RemainingTrays,
        CAST(bl.QtyPer * @PartsPerTray AS INT) * @RemainingTrays  AS ProjectedRemainingConsumption,
        oh.OnHand                                                 AS OnHand,
        CASE WHEN (CAST(bl.QtyPer * @PartsPerTray AS INT) * @RemainingTrays) - oh.OnHand > 0
             THEN (CAST(bl.QtyPer * @PartsPerTray AS INT) * @RemainingTrays) - oh.OnHand ELSE 0 END AS Shortfall,
        CASE WHEN oh.OnHand < CAST(bl.QtyPer * @PartsPerTray AS INT) * @RemainingTrays THEN 1 ELSE 0 END AS IsLow
    FROM Parts.BomLine bl
    INNER JOIN Parts.Item i ON i.Id = bl.ChildItemId
    CROSS APPLY (
        SELECT ISNULL(SUM(l.InventoryAvailable), 0) AS OnHand
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @CellLocationId AND sc.Code <> N'Closed'
    ) oh
    WHERE bl.BomId = @BomId
    ORDER BY i.PartNumber;
END;
GO
