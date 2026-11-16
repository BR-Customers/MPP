-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_ListTrays.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.1 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - D6: each tray shows its own LOT (old shape) or its container's LOT (new shape); 'moved from' reads that LOT's draws on the tray.
-- Version:     1.0
-- Description: READ. The trays of one container with the LOT behind each and what it
--              holds now. Trays emptied by a repack are still listed (Pieces 0).
--              Read proc: no status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_ListTrays
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id AS ContainerTrayId,
        t.TrayPosition,
        ISNULL(t.PartsClosedCount, 0) AS Pieces,
        COALESCE(t.FinishedGoodLotId, cn.LotId) AS LotId,   -- 0119: tray LOT, or the container's LOT
        l.LotName,
        ISNULL(l.CrtActive, 0) AS CrtActive,
        src.LotName AS MovedFromLotName
    FROM Lots.ContainerTray t
    INNER JOIN Lots.Container cn ON cn.Id = t.ContainerId
    LEFT JOIN Lots.Lot l ON l.Id = COALESCE(t.FinishedGoodLotId, cn.LotId)
    OUTER APPLY (SELECT TOP 1 sl.LotName
                 FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot sl ON sl.Id = ce.SourceLotId
                 WHERE ce.ProducedLotId = COALESCE(t.FinishedGoodLotId, cn.LotId) AND ce.TrayId = t.Id
                   AND ce.ConsumedItemId = ce.ProducedItemId
                 ORDER BY ce.Id) src
    WHERE t.ContainerId = @ContainerId
    ORDER BY t.TrayPosition, t.Id;
END;
GO
