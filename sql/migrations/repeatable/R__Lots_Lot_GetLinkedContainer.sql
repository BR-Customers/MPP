-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLinkedContainer.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-04
-- Version:     1.1 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - 7.6: resolves a tray LOT (tray fields filled) or a container LOT (tray fields NULL) via Lots.ufn_LotContainers; + TrayCount (last column).
-- Version:     1.0
-- Description: Returns the Container a finished-good LOT is packed into, via the 1:1
--              Lots.ContainerTray.FinishedGoodLotId link (migration 0034). At most one
--              row (filtered-unique on FinishedGoodLotId). Includes tray position +
--              closure method, container status/location, opened/completed times
--              (ET at the read boundary, OI-36), and the active AIM shipper id when a
--              shipping label exists. Empty result set = LOT not linked to a container
--              (raw / in-process / not-yet-assembled). READ proc: one result set, no
--              status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLinkedContainer
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Id                 AS ContainerId,
        ct.Id                AS ContainerTrayId,
        ct.TrayPosition      AS TrayPosition,
        ct.ClosureMethod     AS ClosureMethod,
        CAST(ct.ClosedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS TrayClosedAt,
        c.ItemId             AS ItemId,
        ci.PartNumber        AS ItemPartNumber,
        csc.Code             AS ContainerStatusCode,
        csc.Name             AS ContainerStatusName,
        c.CurrentLocationId  AS CurrentLocationId,
        loc.Name             AS CurrentLocationName,
        CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt,
        sl.AimShipperId      AS AimShipperId,
        tc.TrayCount         AS TrayCount
    -- 0119: a tray LOT (old shape; tray fields filled) or a container LOT (tray fields NULL)
    FROM Lots.ufn_LotContainers(@LotId) lc
    INNER JOIN Lots.Container            c   ON c.Id   = lc.ContainerId
    LEFT  JOIN Lots.ContainerTray        ct  ON ct.Id  = lc.ContainerTrayId
    OUTER APPLY (SELECT COUNT(*) AS TrayCount FROM Lots.ContainerTray t WHERE t.ContainerId = c.Id) tc
    LEFT  JOIN Lots.ContainerStatusCode  csc ON csc.Id = c.ContainerStatusCodeId
    LEFT  JOIN Location.Location         loc ON loc.Id = c.CurrentLocationId
    LEFT  JOIN Parts.Item                ci  ON ci.Id  = c.ItemId
    OUTER APPLY (
        SELECT TOP 1 s.AimShipperId
        FROM Lots.ShippingLabel s
        WHERE s.ContainerId = c.Id AND s.IsVoid = 0
        ORDER BY s.CreatedAt DESC
    ) sl;
END;
GO
