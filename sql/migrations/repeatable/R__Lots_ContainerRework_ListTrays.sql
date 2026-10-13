-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_ListTrays.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
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
        t.FinishedGoodLotId AS LotId,
        l.LotName,
        ISNULL(l.CrtActive, 0) AS CrtActive,
        src.LotName AS MovedFromLotName
    FROM Lots.ContainerTray t
    LEFT JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
    OUTER APPLY (SELECT TOP 1 sl.LotName
                 FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot sl ON sl.Id = ce.SourceLotId
                 WHERE ce.ProducedLotId = t.FinishedGoodLotId AND ce.TrayId = t.Id
                   AND ce.ConsumedItemId = ce.ProducedItemId
                 ORDER BY ce.Id) src
    WHERE t.ContainerId = @ContainerId
    ORDER BY t.TrayPosition, t.Id;
END;
GO
