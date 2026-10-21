-- ============================================================
-- Repeatable:  R__Quality_Hold_ListAssociatedContainers.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1
-- Description: FAT-QH-170 (FDS-08-007, SHOULD). Advisory read: returns the DISTINCT
--              containers associated with a LOT, so the Hold Management view can
--              alert the operator (when a LOT is held) that related containers may
--              also need a hold. Read-only -- no audit, no mutation, no OUTPUT
--              params, single result set (FDS-11-011). Empty result = no
--              associated containers.
--
--              Two association paths (no direct Container.LotId column exists):
--                A) FG-lot-is-a-tray  : Lots.ContainerTray.FinishedGoodLotId = @LotId
--                B) producing LOT     : Lots.SerializedPart.ProducingLotId = @LotId
--                                       -> Lots.ContainerSerial -> ContainerId
--              A container reachable by BOTH paths is returned ONCE (dedupe by
--              ContainerId; the tray path wins the AssociationKind label).
--
--              v1.1 (super-lot piece 6): RemovedAt (ET) / RemovedReason / MovedInFromContainerName,
--              LAST, about THIS LOT's serials only: scrapped out of the container (kept, marked),
--              or moved in from another container by a repack. NULL when untouched.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Hold_ListAssociatedContainers
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH assoc AS (
        -- Path A: finished-good tray whose LOT is this LOT
        SELECT ct.ContainerId AS ContainerId, 1 AS ViaTray, 0 AS ViaSerial
        FROM Lots.ContainerTray ct
        WHERE ct.FinishedGoodLotId = @LotId
        UNION ALL
        -- Path B: serialized parts produced by this LOT, placed into containers
        SELECT cs.ContainerId, 0, 1
        FROM Lots.SerializedPart sp
        INNER JOIN Lots.ContainerSerial cs ON cs.SerializedPartId = sp.Id
        WHERE sp.ProducingLotId = @LotId
    ),
    rolled AS (
        SELECT ContainerId,
               MAX(ViaTray)   AS ViaTray,
               MAX(ViaSerial) AS ViaSerial
        FROM assoc
        GROUP BY ContainerId
    )
    SELECT
        c.Id                                                       AS ContainerId,
        i.PartNumber                                               AS ItemPartNumber,
        i.Description                                              AS ItemDescription,
        loc.Name                                                   AS CurrentLocationName,
        csc.Code                                                   AS ContainerStatusCode,
        CASE WHEN r.ViaTray = 1 THEN N'FinishedGoodTray'
             ELSE N'SerializedPart' END                            AS AssociationKind,
        CAST(rem.At AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RemovedAt,
        rem.Reason                                                 AS RemovedReason,
        mvin.FromName                                              AS MovedInFromContainerName
    FROM rolled r
    INNER JOIN Lots.Container           c   ON c.Id   = r.ContainerId
    INNER JOIN Parts.Item               i   ON i.Id   = c.ItemId
    INNER JOIN Location.Location        loc ON loc.Id = c.CurrentLocationId
    INNER JOIN Lots.ContainerStatusCode csc ON csc.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        -- this LOT's serials taken out of the container by a repack: scrapped first, else latest move-out
        SELECT TOP (1) e.At, e.Reason FROM (
            SELECT cs.RemovedAt AS At, 1 AS Pri, cs.Id AS Sid,
                   N'Scrapped (' + ISNULL(dc.Description, N'no defect') + N')' AS Reason
            FROM Lots.ContainerSerial cs
            INNER JOIN Lots.SerializedPart  sp ON sp.Id = cs.SerializedPartId AND sp.ProducingLotId = @LotId
            LEFT JOIN Workorder.RejectEvent re ON re.Id = cs.RemovedRejectEventId
            LEFT JOIN Quality.DefectCode    dc ON dc.Id = re.DefectCodeId
            WHERE cs.ContainerId = c.Id AND cs.RemovedAt IS NOT NULL
            UNION ALL
            SELECT h.MigratedAt, 2, h.ContainerSerialId,
                   N'Moved to container ' + CAST(h.NewContainerId AS NVARCHAR(20))
            FROM Lots.ContainerSerialHistory h
            INNER JOIN Lots.ContainerSerial cs2 ON cs2.Id = h.ContainerSerialId
            INNER JOIN Lots.SerializedPart  sp2 ON sp2.Id = cs2.SerializedPartId AND sp2.ProducingLotId = @LotId
            WHERE h.OldContainerId = c.Id AND h.NewContainerId <> c.Id
        ) e
        ORDER BY e.Pri, e.At DESC, e.Sid DESC
    ) rem
    OUTER APPLY (
        SELECT TOP (1) CAST(h.OldContainerId AS NVARCHAR(50)) AS FromName
        FROM Lots.ContainerSerialHistory h
        INNER JOIN Lots.ContainerSerial cs3 ON cs3.Id = h.ContainerSerialId
        INNER JOIN Lots.SerializedPart  sp3 ON sp3.Id = cs3.SerializedPartId AND sp3.ProducingLotId = @LotId
        WHERE h.NewContainerId = c.Id AND h.OldContainerId <> c.Id
        ORDER BY h.MigratedAt DESC, h.Id DESC
    ) mvin
    ORDER BY c.Id;
END;
GO
