-- ============================================================
-- Repeatable:  R__Lots_Lot_GetShippedContainers.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: The shipped-container / Honda-AIM band for the LOT Genealogy &
--              Traceability report. Returns every finished-good container the LOT
--              reached: the subject LOT itself PLUS all of its genealogy descendants
--              (recursive edge walk), joined to any container they were packed into
--              via Lots.ContainerTray.FinishedGoodLotId, with the active (non-void)
--              AIM shipper id off the shipping label. Each row names its FG LOT so a
--              multi-descendant band stays legible.
--
--              A subject that is itself an FG degenerates correctly (its own container
--              is included because the descendant set is seeded with the subject).
--
--              READ proc (FDS-11-011): no status row, ONE result set, empty = the LOT
--              has reached no FG container yet, no OUTPUT params. CompletedAt is ET at
--              the read boundary. Lot_GetLinkedContainer remains the single-LOT lookup;
--              this proc is the report's descendant-aware view.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetShippedContainers
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Reach AS (
        -- Seed with the subject itself, then walk down every consumption edge.
        SELECT @LotId AS LotId,
               CAST(N'/' + CAST(@LotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        UNION ALL
        SELECT g.ChildLotId,
               CAST(r.Path + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Reach r ON g.ParentLotId = r.LotId
        WHERE r.Path NOT LIKE N'%/' + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/%'
    )
    SELECT
        ct.FinishedGoodLotId,
        fgl.LotName          AS FinishedGoodLotName,
        fgi.PartNumber       AS FinishedGoodPartNumber,
        c.Id                 AS ContainerId,
        sl.AimShipperId,
        ct.PartsClosedCount  AS Quantity,
        csc.Name             AS ContainerStatusName,
        loc.Name             AS CurrentLocationName,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt
    FROM Lots.ContainerTray ct
    INNER JOIN (SELECT DISTINCT LotId FROM Reach) r ON r.LotId = ct.FinishedGoodLotId
    INNER JOIN Lots.Container            c   ON c.Id   = ct.ContainerId
    INNER JOIN Lots.Lot                  fgl ON fgl.Id = ct.FinishedGoodLotId
    INNER JOIN Parts.Item                fgi ON fgi.Id = fgl.ItemId
    LEFT  JOIN Lots.ContainerStatusCode  csc ON csc.Id = c.ContainerStatusCodeId
    LEFT  JOIN Location.Location         loc ON loc.Id = c.CurrentLocationId
    OUTER APPLY (
        SELECT TOP 1 s.AimShipperId
        FROM Lots.ShippingLabel s
        WHERE s.ContainerId = c.Id AND s.IsVoid = 0
        ORDER BY s.CreatedAt DESC
    ) sl
    ORDER BY fgl.LotName, c.Id
    OPTION (MAXRECURSION 100);
END;
GO
