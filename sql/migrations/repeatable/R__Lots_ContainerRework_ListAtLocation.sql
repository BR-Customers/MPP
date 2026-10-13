-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_ListAtLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. Refill-ready containers waiting at a location (a line) or
--              anywhere under it. Feeds the button on the line's inventory card: it is
--              shown only while this returns a row (spec D8).
--              Read proc: no status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_ListAtLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT @LocationId AS Id WHERE @LocationId IS NOT NULL
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    SELECT
        c.Id AS ContainerId,
        i.PartNumber,
        i.Description AS ItemDescription,
        ISNULL(acc.Pieces, 0) AS Pieces,
        cc.TraysPerContainer * cc.PartsPerTray AS TargetParts,
        (cc.TraysPerContainer * cc.PartsPerTray) - ISNULL(acc.Pieces, 0) AS ShortBy,
        cc.PartsPerTray,
        run.RunNumber
    FROM Lots.Container c
    INNER JOIN Parts.Item i            ON i.Id = c.ItemId
    LEFT JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
    OUTER APPLY (SELECT SUM(t.PartsClosedCount) AS Pieces FROM Lots.ContainerTray t
                 WHERE t.ContainerId = c.Id AND t.ClosedAt IS NOT NULL) acc
    OUTER APPLY (SELECT TOP 1 r.RunNumber
                 FROM Quality.ControlledRunMember m INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
                 WHERE m.ContainerId = c.Id AND m.EndedAt IS NULL) run
    WHERE c.ContainerStatusCodeId = 7 /* ReworkFilling */
      AND c.CurrentLocationId IN (SELECT Id FROM Descendants)
    ORDER BY c.Id
    OPTION (MAXRECURSION 8);
END;
GO
