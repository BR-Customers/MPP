-- ============================================================
-- Repeatable:  R__Lots_Lot_GetShippedContainers.sql
-- Author:      Blue Ridge Automation
-- Version:     1.2 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - Review I1 / M3: reach via the genealogy closure (not an edge walk); a container LOT's quantity is its own LOT-less trays.
-- Version:     1.1 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - D8: reads the container's finished-good LOT(s) in BOTH shapes through Lots.ufn_ContainerLots / ufn_LotContainers.
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

    -- Container-as-LOT (review I1): reach is the genealogy CLOSURE -- the same
    -- authority as the Honda trace, written when each edge is recorded. A recursive walk
    -- of the edges over-reaches once a long-lived container LOT gains ancestors after it
    -- gave pieces away (a reworked container topped up later): the later source never
    -- reached the pieces that had already left. The closure also replaces the
    -- path-enumerating recursion, which grew with every path.
    ;WITH Reach AS (
        SELECT gc.DescendantLotId AS LotId
        FROM Lots.LotGenealogyClosure gc
        WHERE gc.AncestorLotId = @LotId
    )
    SELECT
        lc.FinishedGoodLotId,
        fgl.LotName          AS FinishedGoodLotName,
        fgi.PartNumber       AS FinishedGoodPartNumber,
        c.Id                 AS ContainerId,
        sl.AimShipperId,
        lc.Quantity          AS Quantity,
        csc.Name             AS ContainerStatusName,
        loc.Name             AS CurrentLocationName,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt
    -- 0119: a reached LOT is packed as a tray LOT (quantity = that tray) or as a
    -- container LOT (quantity = the whole container's trays).
    FROM Reach r
    CROSS APPLY (
        SELECT x.ContainerId, r.LotId AS FinishedGoodLotId,
               CASE WHEN x.ContainerTrayId IS NOT NULL
                    THEN (SELECT t.PartsClosedCount FROM Lots.ContainerTray t WHERE t.Id = x.ContainerTrayId)
                    -- a container LOT holds its container's LOT-less trays (a mixed container's
                    -- old trays belong to their own tray LOTs -- review M3)
                    ELSE (SELECT SUM(t.PartsClosedCount) FROM Lots.ContainerTray t
                          WHERE t.ContainerId = x.ContainerId AND t.FinishedGoodLotId IS NULL) END AS Quantity
        FROM Lots.ufn_LotContainers(r.LotId) x
    ) lc
    INNER JOIN Lots.Container            c   ON c.Id   = lc.ContainerId
    INNER JOIN Lots.Lot                  fgl ON fgl.Id = lc.FinishedGoodLotId
    INNER JOIN Parts.Item                fgi ON fgi.Id = fgl.ItemId
    LEFT  JOIN Lots.ContainerStatusCode  csc ON csc.Id = c.ContainerStatusCodeId
    LEFT  JOIN Location.Location         loc ON loc.Id = c.CurrentLocationId
    OUTER APPLY (
        SELECT TOP 1 s.AimShipperId
        FROM Lots.ShippingLabel s
        WHERE s.ContainerId = c.Id AND s.IsVoid = 0
        ORDER BY s.CreatedAt DESC
    ) sl
    ORDER BY fgl.LotName, c.Id;
END;
GO
