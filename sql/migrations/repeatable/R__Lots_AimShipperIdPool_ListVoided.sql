-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_ListVoided.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. Shipper serials the MES has voided because their container was
--              opened for rework (spec D3). AIM has been told NOTHING about them.
--              WasPosted = 1 rows are the ones AIM still believes are good: this is the
--              worklist for the cancellation post under discussion with MPP.
--              Read proc: no status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_ListVoided
    @OnlyPosted BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1000
        p.Id,
        p.AimShipperId,
        p.ConsumedByContainerId AS ContainerId,
        i.PartNumber,
        p.Quantity,
        p.LotNumber,
        CONVERT(BIT, CASE WHEN p.PostedAt IS NOT NULL THEN 1 ELSE 0 END) AS WasPosted,
        CAST(p.PostedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PostedAt,
        CAST(p.VoidedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS VoidedAt,
        u.Initials AS VoidedByInitials,
        p.VoidReason,
        live.AimShipperId AS ReplacedByAimShipperId
    FROM Lots.AimShipperIdPool p
    LEFT JOIN Lots.Container c    ON c.Id = p.ConsumedByContainerId
    LEFT JOIN Parts.Item i        ON i.Id = c.ItemId
    LEFT JOIN Location.AppUser u  ON u.Id = p.VoidedByUserId
    OUTER APPLY (SELECT TOP 1 n.AimShipperId FROM Lots.AimShipperIdPool n
                 WHERE n.ConsumedByContainerId = p.ConsumedByContainerId AND n.VoidedAt IS NULL
                 ORDER BY n.ConsumedAt DESC, n.Id DESC) live
    WHERE p.VoidedAt IS NOT NULL
      AND (ISNULL(@OnlyPosted, 0) = 0 OR p.PostedAt IS NOT NULL)
    ORDER BY p.VoidedAt DESC, p.Id DESC;
END;
GO
