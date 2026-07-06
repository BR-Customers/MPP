-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventoryByPart.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.0
-- Description: On-hand inventory at a location, grouped by part then FIFO by
--              arrival. Returns OPEN on-hand LOTs (LotStatusCode <> 'Closed' AND
--              InventoryAvailable > 0) whose CurrentLocationId = @LocationId, one
--              row per LOT. ArrivedAt is the LOT's latest LotMovement.MovedAt into
--              @LocationId (falling back to Lot.CreatedAt when the LOT never moved
--              in), ET-converted at the read boundary. Ordered PartNumber ASC,
--              ArrivedAt ASC, LotId ASC so callers see parts grouped and FIFO
--              within each part. Read proc; empty rowset = nothing on hand.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineInventoryByPart
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    ;WITH LastArrival AS (
        SELECT m.LotId, MAX(m.MovedAt) AS ArrivedAtUtc
        FROM Lots.LotMovement m
        WHERE m.ToLocationId = @LocationId
        GROUP BY m.LotId
    )
    SELECT
        l.ItemId,
        i.PartNumber,
        i.Description,
        l.Id                 AS LotId,
        l.LotName,
        l.InventoryAvailable,
        CAST(COALESCE(la.ArrivedAtUtc, l.CreatedAt)
             AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAt
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    LEFT  JOIN LastArrival la        ON la.LotId = l.Id
    WHERE l.CurrentLocationId = @LocationId
      AND sc.Code <> N'Closed'
      AND l.InventoryAvailable > 0
    ORDER BY i.PartNumber ASC,
             COALESCE(la.ArrivedAtUtc, l.CreatedAt) ASC,
             l.Id ASC;
END;
GO
