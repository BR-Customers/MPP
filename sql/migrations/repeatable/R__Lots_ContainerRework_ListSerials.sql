-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_ListSerials.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. The serials still in one container (a scrapped serial is not
--              listed), with the tray each sits in. Empty for a part that is not
--              serialized.
--              Read proc: no status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_ListSerials
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        s.Id AS ContainerSerialId,
        sp.SerialNumber,
        -- a serial moved by Sort Cage has no tray; it is handled against the container's first tray with pieces
        COALESCE(s.ContainerTrayId, ft.Id) AS ContainerTrayId,
        COALESCE(t.TrayPosition, ft.TrayPosition) AS TrayPosition,
        pl.LotName AS ProducingLotName
    FROM Lots.ContainerSerial s
    INNER JOIN Lots.SerializedPart sp ON sp.Id = s.SerializedPartId
    LEFT JOIN Lots.ContainerTray t    ON t.Id = s.ContainerTrayId
    LEFT JOIN Lots.Lot pl             ON pl.Id = sp.ProducingLotId
    OUTER APPLY (SELECT TOP 1 x.Id, x.TrayPosition FROM Lots.ContainerTray x
                 WHERE x.ContainerId = s.ContainerId AND ISNULL(x.PartsClosedCount, 0) > 0
                 ORDER BY x.TrayPosition, x.Id) ft
    WHERE s.ContainerId = @ContainerId AND s.RemovedAt IS NULL
    ORDER BY COALESCE(t.TrayPosition, ft.TrayPosition), sp.SerialNumber;
END;
GO
