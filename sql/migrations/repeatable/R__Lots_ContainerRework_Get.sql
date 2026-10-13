-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_Get.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. One container as the Repack screen needs it: what it is, where
--              it is, how full it is, and -- as columns, so no view works them out --
--              what may be done to it NOW (CanOpen, CanScrapOrMove, CanSetFilling,
--              CanSetProcessing, CanCompleteHere, CanVoid). The procs remain the judges.
--              Empty set = unknown container.
--              Read proc: no status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_Get
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Id AS ContainerId,
        cs.Code AS StatusCode,
        cs.Name AS StatusName,
        c.ItemId,
        i.PartNumber,
        i.Description AS ItemDescription,
        c.CurrentLocationId,
        lo.Name AS CurrentLocationName,
        ISNULL(cc.IsSerialized, 0) AS IsSerialized,
        cc.TraysPerContainer * cc.PartsPerTray AS TargetParts,
        ISNULL(acc.Pieces, 0) AS Pieces,
        CASE WHEN cc.TraysPerContainer * cc.PartsPerTray IS NULL THEN 0
             ELSE (cc.TraysPerContainer * cc.PartsPerTray) - ISNULL(acc.Pieces, 0) END AS ShortBy,
        live.AimShipperId AS LiveAimShipperId,
        rw.OriginalAimShipperId,
        CAST(rw.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReworkOpenedAt,
        ou.Initials AS ReworkOpenedByInitials,
        run.RunNumber,
        run.ControlledRunId,
        run.MemberId,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId IN (6, 7) THEN 1
                          WHEN c.ContainerStatusCodeId = 1 AND rw.ResumedAt IS NOT NULL AND rw.VoidedAt IS NULL THEN 1
                          ELSE 0 END) AS InRework,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId = 2 THEN 1 ELSE 0 END) AS CanOpen,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId IN (6, 7) AND ISNULL(acc.Pieces, 0) > 0 THEN 1 ELSE 0 END) AS CanScrapOrMove,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId = 6 THEN 1
                          WHEN c.ContainerStatusCodeId = 1 AND rw.ResumedAt IS NOT NULL AND rw.VoidedAt IS NULL THEN 1
                          ELSE 0 END) AS CanSetFilling,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId = 7 THEN 1 ELSE 0 END) AS CanSetProcessing,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId = 7 AND cc.TraysPerContainer * cc.PartsPerTray IS NOT NULL
                               AND ISNULL(acc.Pieces, 0) = cc.TraysPerContainer * cc.PartsPerTray THEN 1 ELSE 0 END) AS CanCompleteHere,
        CONVERT(BIT, CASE WHEN c.ContainerStatusCodeId IN (6, 7) AND ISNULL(acc.Pieces, 0) = 0 THEN 1 ELSE 0 END) AS CanVoid
    FROM Lots.Container c
    INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    INNER JOIN Parts.Item i                ON i.Id = c.ItemId
    LEFT JOIN Parts.ContainerConfig cc     ON cc.Id = c.ContainerConfigId
    LEFT JOIN Location.Location lo         ON lo.Id = c.CurrentLocationId
    OUTER APPLY (SELECT SUM(t.PartsClosedCount) AS Pieces FROM Lots.ContainerTray t
                 WHERE t.ContainerId = c.Id AND t.ClosedAt IS NOT NULL) acc
    OUTER APPLY (SELECT TOP 1 r.* FROM Lots.ContainerRework r WHERE r.ContainerId = c.Id ORDER BY r.Id DESC) rw
    LEFT JOIN Location.AppUser ou          ON ou.Id = rw.OpenedByUserId
    OUTER APPLY (SELECT TOP 1 p.AimShipperId FROM Lots.AimShipperIdPool p
                 WHERE p.ConsumedByContainerId = c.Id AND p.VoidedAt IS NULL ORDER BY p.ConsumedAt DESC, p.Id DESC) live
    OUTER APPLY (SELECT TOP 1 r.RunNumber, r.Id AS ControlledRunId, m.Id AS MemberId
                 FROM Quality.ControlledRunMember m INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
                 WHERE m.ContainerId = c.Id AND m.EndedAt IS NULL) run
    WHERE c.Id = @ContainerId;
END;
GO
