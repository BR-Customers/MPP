-- ============================================================
-- Repeatable:  R__Quality_Hold_ListAssociatedContainers.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
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
             ELSE N'SerializedPart' END                            AS AssociationKind
    FROM rolled r
    INNER JOIN Lots.Container           c   ON c.Id   = r.ContainerId
    INNER JOIN Parts.Item               i   ON i.Id   = c.ItemId
    INNER JOIN Location.Location        loc ON loc.Id = c.CurrentLocationId
    INNER JOIN Lots.ContainerStatusCode csc ON csc.Id = c.ContainerStatusCodeId
    ORDER BY c.Id;
END;
GO
