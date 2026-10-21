-- =============================================
-- Repeatable:  R__Lots_Container_GetTraceDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.1
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
--
--              v1.1 (super-lot piece 6): repack awareness, new columns LAST --
--              ReplacedSerial / ReplacedSerialVoidedAt / ReworkOpenedAt / ReworkOpenedByInitials
--              from the latest Lots.ContainerRework, then ScrappedSerialCount (serials scrapped out
--              of this container), MovedOutSerialCount, MovedInSerialCount (serials moved out / in
--              per Lots.ContainerSerialHistory -- a repack OR a Sort Cage migration). Counts are 0
--              and the rest NULL for an untouched container. Per-serial detail:
--              Lots.Container_ListSerials @IncludeRemoved = 1.
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
        ISNULL(h.TotalHoldCount, 0) AS TotalHoldCount,
        rwk.OriginalAimShipperId AS ReplacedSerial,
        CAST(rwk.VoidedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReplacedSerialVoidedAt,
        CAST(rwk.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReworkOpenedAt,
        rwk.Initials AS ReworkOpenedByInitials,
        ISNULL(cnt.ScrappedCount, 0) AS ScrappedSerialCount,
        ISNULL(cnt.MovedOutCount, 0) AS MovedOutSerialCount,
        ISNULL(cnt.MovedInCount, 0) AS MovedInSerialCount
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
    OUTER APPLY (
        SELECT TOP (1) rw.OpenedAt, rw.OriginalAimShipperId, ap.VoidedAt, u.Initials
        FROM Lots.ContainerRework rw
        LEFT JOIN Lots.AimShipperIdPool ap ON ap.AimShipperId = rw.OriginalAimShipperId
        LEFT JOIN Location.AppUser      u  ON u.Id = rw.OpenedByUserId
        WHERE rw.ContainerId = c.Id
        ORDER BY rw.OpenedAt DESC, rw.Id DESC
    ) rwk
    OUTER APPLY (
        SELECT
            (SELECT COUNT(*) FROM Lots.ContainerSerial cs
              WHERE cs.ContainerId = c.Id AND cs.RemovedAt IS NOT NULL) AS ScrappedCount,
            (SELECT COUNT(DISTINCT h.ContainerSerialId)
               FROM Lots.ContainerSerialHistory h
               INNER JOIN Lots.ContainerSerial cs ON cs.Id = h.ContainerSerialId
              WHERE h.OldContainerId = c.Id AND h.NewContainerId <> c.Id AND cs.ContainerId <> c.Id) AS MovedOutCount,
            (SELECT COUNT(DISTINCT h.ContainerSerialId)
               FROM Lots.ContainerSerialHistory h
               INNER JOIN Lots.ContainerSerial cs ON cs.Id = h.ContainerSerialId
              WHERE h.NewContainerId = c.Id AND h.OldContainerId <> c.Id AND cs.ContainerId = c.Id) AS MovedInCount
    ) cnt
    WHERE c.Id = @ContainerId;
END
GO
