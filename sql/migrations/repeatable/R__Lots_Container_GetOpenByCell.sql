-- ============================================================
-- Repeatable:  R__Lots_Container_GetOpenByCell.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Returns the OPEN container(s) at a Cell (Arc 2 Phase 6 assembly read),
--              with the config target + accumulated closed-tray parts so the Assembly
--              views can show fill progress + gate completion. Read proc: no OUTPUT
--              params, empty set = none open. OpenedAt CAST to ET DATETIME2(3) (raw
--              datetimeoffset breaks the Ignition JDBC read).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Container_GetOpenByCell
    @CellLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ct.Id,
        ct.ItemId,
        i.PartNumber                                   AS ItemPartNumber,
        i.Description                                  AS ItemDescription,
        ct.ContainerConfigId,
        cc.TraysPerContainer,
        cc.PartsPerTray,
        cc.IsSerialized,
        cc.ClosureMethod,
        (cc.TraysPerContainer * cc.PartsPerTray)       AS TargetParts,
        ISNULL((SELECT SUM(t.PartsClosedCount) FROM Lots.ContainerTray t
                WHERE t.ContainerId = ct.Id AND t.ClosedAt IS NOT NULL), 0) AS AccumulatedParts,
        (SELECT COUNT(*) FROM Lots.ContainerTray t WHERE t.ContainerId = ct.Id AND t.ClosedAt IS NOT NULL) AS ClosedTrays,
        CAST(ct.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt
    FROM Lots.Container ct
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId
    INNER JOIN Parts.ContainerConfig cc ON cc.Id = ct.ContainerConfigId
    WHERE ct.CurrentLocationId = @CellLocationId
      AND ct.ContainerStatusCodeId = 1   -- Open
    ORDER BY ct.OpenedAt;
END;
GO
