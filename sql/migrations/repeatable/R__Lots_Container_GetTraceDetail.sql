-- =============================================
-- Repeatable:  R__Lots_Container_GetTraceDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-003 Container Search payload, rendered as a detail panel
--              on Global Trace. One result set (FDS-11-011); empty set means
--              the container is unknown -- no invented 404.
--
--              The serial list and hold history are SIBLING procs
--              (Lots.Container_ListSerials, Quality.Hold_ListByContainer) --
--              one proc, one result set. Counts are surfaced here so the panel
--              can render a summary without calling them.
--
--              Containers have no name column; identity is the container Id and
--              the AIM shipper Id on the Honda label (design spec 2.4).
--              CompletedAt is container CLOSE time, NOT ship time (spec 2.5).
--
--              Source LOTs are counted the way GlobalTrace_Resolve expands a
--              container: ContainerTray.FinishedGoodLotId (migration 0034)
--              UNIONed with ContainerSerial -> SerializedPart.ProducingLotId.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Container_GetTraceDetail
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Id AS ContainerId,
        c.ItemId,
        i.PartNumber AS ItemPartNumber,
        csc.Code     AS ContainerStatusCode,
        ISNULL(tray.PieceCount, 0)    AS PieceCount,
        ISNULL(ser.SerialCount, 0)    AS SerialCount,
        ISNULL(src.SourceLotCount, 0) AS SourceLotCount,
        CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt,
        lbl.AimShipperId,
        ISNULL(h.OpenHoldCount, 0)  AS OpenHoldCount,
        ISNULL(h.TotalHoldCount, 0) AS TotalHoldCount
    FROM Lots.Container c
    INNER JOIN Parts.Item i ON i.Id = c.ItemId
    INNER JOIN Lots.ContainerStatusCode csc ON csc.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        SELECT SUM(ct.PartsClosedCount) AS PieceCount
        FROM Lots.ContainerTray ct WHERE ct.ContainerId = c.Id
    ) tray
    OUTER APPLY (
        SELECT COUNT(*) AS SerialCount
        FROM Lots.ContainerSerial cs WHERE cs.ContainerId = c.Id
    ) ser
    OUTER APPLY (
        SELECT COUNT(*) AS SourceLotCount FROM (
            SELECT ct.FinishedGoodLotId AS LotId
            FROM Lots.ContainerTray ct
            WHERE ct.ContainerId = c.Id AND ct.FinishedGoodLotId IS NOT NULL
            UNION
            SELECT sp.ProducingLotId
            FROM Lots.ContainerSerial cs
            INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
            WHERE cs.ContainerId = c.Id
        ) u
    ) src
    OUTER APPLY (
        SELECT TOP (1) sl.AimShipperId
        FROM Lots.ShippingLabel sl
        WHERE sl.ContainerId = c.Id AND sl.IsVoid = 0
        ORDER BY sl.CreatedAt DESC, sl.Id DESC
    ) lbl
    OUTER APPLY (
        SELECT COUNT(*) AS TotalHoldCount,
               SUM(CASE WHEN he.ReleasedAt IS NULL THEN 1 ELSE 0 END) AS OpenHoldCount
        FROM Quality.HoldEvent he WHERE he.ContainerId = c.Id
    ) h
    WHERE c.Id = @ContainerId;
END
GO
