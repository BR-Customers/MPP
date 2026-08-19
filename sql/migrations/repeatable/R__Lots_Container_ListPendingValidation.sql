-- ============================================================
-- Repeatable:  R__Lots_Container_ListPendingValidation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-18
-- Version:     1.0
-- Description: Containers awaiting Controlled Run Tag validation: their finished-good
--              LOT is still CrtActive, so their AIM Shipper ID is claimed but held.
--
--              A container carries ONE finished-good LOT PER TRAY
--              (Lots.ContainerTray.FinishedGoodLotId is 1:1 with the tray), so a 4-tray
--              container has 4 CRT-active LOTs. A container is pending while ANY of them
--              is still CrtActive; PendingLotCount reports how many.
--
--              @LocationId scopes to that location and every descendant (mirrors
--              Lot_GetWipQueueByLocation's Descendants CTE) - callers pass the
--              terminal's PARENT LINE. @ContainerId probes one container instead
--              (used by the completion path to decide whether to post).
--              Exactly one of the two should be supplied.
--
--              Read proc: no OUTPUT params, empty result set = nothing pending.
--              Times are ET-converted and CAST to DATETIME2(3) - a raw
--              datetimeoffset breaks the Ignition JDBC result read.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Container_ListPendingValidation
    @LocationId  BIGINT = NULL,
    @ContainerId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    SELECT
        c.Id                                AS ContainerId,
        i.PartNumber                        AS ItemPartNumber,
        i.Description                       AS ItemDescription,
        ISNULL(SUM(ct.PartsClosedCount), 0) AS PieceCount,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3))               AS CompletedAtEt,
        MAX(p.AimShipperId)                 AS AimShipperId,
        DATEDIFF(MINUTE, c.CompletedAt, SYSUTCDATETIME()) AS AgeMinutes,
        COUNT(*)                            AS PendingLotCount
    FROM Lots.Container c
    INNER JOIN Lots.ContainerTray ct ON ct.ContainerId = c.Id
    INNER JOIN Lots.Lot fgl          ON fgl.Id = ct.FinishedGoodLotId AND fgl.CrtActive = 1
    INNER JOIN Parts.Item i          ON i.Id = c.ItemId
    LEFT  JOIN Lots.AimShipperIdPool p ON p.ConsumedByContainerId = c.Id
    WHERE (@ContainerId IS NOT NULL AND c.Id = @ContainerId)
       OR (@ContainerId IS NULL AND @LocationId IS NOT NULL
           AND c.CurrentLocationId IN (SELECT Id FROM Descendants))
    GROUP BY c.Id, i.PartNumber, i.Description, c.CompletedAt
    ORDER BY c.CompletedAt, c.Id
    OPTION (MAXRECURSION 8);
END;
GO
