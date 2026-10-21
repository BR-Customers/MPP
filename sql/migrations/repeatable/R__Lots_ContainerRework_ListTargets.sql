-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_ListTargets.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. Where pieces from this container can go: every OTHER container
--              of the same part that is refill-ready (ReworkFilling) and has room.
--              The same test Lots.ContainerRework_MovePieces applies.
--              Read proc: no status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_ListTargets
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Id AS ContainerId,
        lo.Name AS CurrentLocationName,
        ISNULL(acc.Pieces, 0) AS Pieces,
        cc.TraysPerContainer * cc.PartsPerTray AS TargetParts,
        (cc.TraysPerContainer * cc.PartsPerTray) - ISNULL(acc.Pieces, 0) AS Room
    FROM Lots.Container src
    INNER JOIN Lots.Container c        ON c.ItemId = src.ItemId AND c.Id <> src.Id AND c.ContainerStatusCodeId = 7
    LEFT JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
    LEFT JOIN Location.Location lo     ON lo.Id = c.CurrentLocationId
    OUTER APPLY (SELECT SUM(t.PartsClosedCount) AS Pieces FROM Lots.ContainerTray t
                 WHERE t.ContainerId = c.Id AND t.ClosedAt IS NOT NULL) acc
    WHERE src.Id = @ContainerId
      AND (cc.TraysPerContainer * cc.PartsPerTray IS NULL
           OR ISNULL(acc.Pieces, 0) < cc.TraysPerContainer * cc.PartsPerTray)
    ORDER BY c.Id;
END;
GO
