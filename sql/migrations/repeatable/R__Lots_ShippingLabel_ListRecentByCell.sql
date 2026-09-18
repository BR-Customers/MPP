-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_ListRecentByCell.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Recent container shipping labels at an Assembly OUT cell -- the pick
--              list for the elevated reprint popup
--              (BlueRidge/Components/PlantFloor/ShippingLabelReprint).
--
--              Scoped by the CONTAINER's location (Container.CurrentLocationId at or
--              under @CellLocationId), not by ShippingLabel.TerminalLocationId: a
--              PLC-completed container has no terminal, and both terminals on a line
--              must see the same list.
--
--              ONE ROW PER CONTAINER -- its newest non-void label. A container that
--              has been reprinted three times would otherwise fill the list with
--              duplicates; which row is reprinted does not matter, because
--              Lots.ShippingLabel_Reprint re-renders the ZPL fresh from the container.
--              Voided labels are dropped BEFORE the newest is picked, and containers
--              whose status is Void are excluded outright.
--
--              Serial mirrors Lots.ufn_ShippingLabelZpl ('13218001' + last 8 of the
--              AIM serial) so the operator matches the list to the physical label.
--              Quantity mirrors the label's {Quantity} (sum of closed trays).
--              PrintStatus: Printed / Failed / Pending, from PrintedAt / PrintFailedAt.
--              Times converted UTC -> Eastern at the boundary.
--
--              Read proc: one result set, no OUTPUT params, empty = none (FDS-11-011).
--              NULL @CellLocationId returns an empty set. @TopN NULL or < 1 -> 10.
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_ListRecentByCell
    @CellLocationId BIGINT,
    @TopN           INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @N INT = CASE WHEN @TopN IS NULL OR @TopN < 1 THEN 10 ELSE @TopN END;

    ;WITH Descendants AS (
        SELECT l.Id FROM Location.Location l WHERE l.Id = @CellLocationId
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    ),
    Ranked AS (
        SELECT sl.Id, sl.ContainerId, sl.AimShipperId, sl.Initial, sl.PrintReasonCode,
               sl.CreatedAt, sl.PrintedAt, sl.PrintFailedAt,
               ROW_NUMBER() OVER (PARTITION BY sl.ContainerId ORDER BY sl.CreatedAt DESC, sl.Id DESC) AS Rn
        FROM Lots.ShippingLabel sl
        INNER JOIN Lots.Container c              ON c.Id = sl.ContainerId
        INNER JOIN Lots.ContainerStatusCode csc  ON csc.Id = c.ContainerStatusCodeId
        WHERE sl.IsVoid = 0
          AND csc.Code <> N'Void'
          AND c.CurrentLocationId IN (SELECT Id FROM Descendants)
    )
    SELECT TOP (@N)
        r.Id,
        r.ContainerId,
        r.AimShipperId,
        N'13218001' + RIGHT(r.AimShipperId, 8) AS Serial,
        c.ItemId,
        i.PartNumber,
        i.Description AS ItemDescription,
        ISNULL((SELECT SUM(ct.PartsClosedCount) FROM Lots.ContainerTray ct
                WHERE ct.ContainerId = r.ContainerId AND ct.ClosedAt IS NOT NULL), 0) AS Quantity,
        r.Initial,
        r.PrintReasonCode,
        CASE WHEN r.PrintedAt     IS NOT NULL THEN N'Printed'
             WHEN r.PrintFailedAt IS NOT NULL THEN N'Failed'
             ELSE N'Pending' END AS PrintStatus,
        CAST(r.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        CAST(r.PrintedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PrintedAt
    FROM Ranked r
    INNER JOIN Lots.Container c ON c.Id = r.ContainerId
    INNER JOIN Parts.Item i     ON i.Id = c.ItemId
    WHERE r.Rn = 1
    ORDER BY r.CreatedAt DESC, r.Id DESC
    OPTION (MAXRECURSION 8);
END;
GO
