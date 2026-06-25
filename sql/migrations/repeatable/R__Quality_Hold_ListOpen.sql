-- ============================================================
-- Repeatable:  R__Quality_Hold_ListOpen.sql
-- Author:      Blue Ridge Automation
-- Description: Lists every OPEN hold (ReleasedAt IS NULL) for the Hold Management
--              screen's open-holds panels (Arc 2 Phase 7). Each row carries the
--              Hold Event Id (to release), the held LOT or Container, hold type,
--              reason, who placed it, and when (displayed Eastern per the UTC->ET
--              convention). Read proc -- no params, no OUTPUT params (FDS-11-011),
--              empty set = no open holds. The screen splits rows by LotId vs
--              ContainerId across its two panels.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Hold_ListOpen
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        he.Id                         AS HoldEventId,
        he.LotId,
        l.LotName,
        he.ContainerId,
        ci.PartNumber                 AS ContainerItemPartNumber,
        he.HoldTypeCodeId,
        htc.Code                      AS HoldTypeCode,
        he.Reason,
        u.Initials                    AS PlacedByInitials,
        CAST(he.PlacedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PlacedAt
    FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode htc ON htc.Id = he.HoldTypeCodeId
    LEFT  JOIN Lots.Lot l              ON l.Id  = he.LotId
    LEFT  JOIN Lots.Container c        ON c.Id  = he.ContainerId
    LEFT  JOIN Parts.Item ci           ON ci.Id = c.ItemId
    LEFT  JOIN Location.AppUser u      ON u.Id  = he.PlacedByUserId
    WHERE he.ReleasedAt IS NULL
    ORDER BY he.PlacedAt, he.Id;
END;
GO
