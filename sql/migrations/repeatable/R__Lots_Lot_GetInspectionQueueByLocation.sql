-- ============================================================
-- Repeatable:  R__Lots_Lot_GetInspectionQueueByLocation.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Third-party inspection station queue (2026-07-24). Returns the OPEN,
--              Received/ReceivedOffsite-origin LOTs sitting at the inspection station
--              (the bought-in parts awaiting inspection / check-out), with their LATEST
--              inspection result (Pass/Fail/Conditional or NULL when not yet inspected),
--              vendor lot, arrival time. Check-out itself is plain assembly-out
--              (Assembly_CompleteTray mints the pass-through FG consuming this component +
--              Container_Complete labels it) -- nothing new there; this read just drives the
--              station's inspect pick-list + pass gate.
--
--              FDS-11-011: no OUTPUT params, single result set, empty set = nothing to show.
--              ET timestamps at the read boundary. Column shape mirrors the WIP queue where
--              it overlaps so the view row transform stays familiar.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetInspectionQueueByLocation
    @LocationId         BIGINT,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS ArrivedAt FROM Lots.LotMovement m GROUP BY m.LotId
    ),
    LastInsp AS (
        SELECT qs.LotId, qs.InspectionResultCodeId, qs.SampledAt,
               ROW_NUMBER() OVER (PARTITION BY qs.LotId ORDER BY qs.SampledAt DESC, qs.Id DESC) AS rn
        FROM Quality.QualitySample qs
    )
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.VendorLotNumber,
        l.LotStatusId, sc.Code AS LotStatusCode,
        irc.Code AS LatestInspectionResult,
        CAST(li.SampledAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LatestSampledAt,
        CAST(lm.ArrivedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAt
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
    INNER JOIN Parts.Item i           ON i.Id  = l.ItemId
    INNER JOIN Lots.LotOriginType ot  ON ot.Id = l.LotOriginTypeId AND ot.Code IN (N'Received', N'ReceivedOffsite')
    LEFT  JOIN LastMove lm            ON lm.LotId = l.Id
    LEFT  JOIN LastInsp li            ON li.LotId = l.Id AND li.rn = 1
    LEFT  JOIN Quality.InspectionResultCode irc ON irc.Id = li.InspectionResultCodeId
    WHERE ( (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
         OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @LocationId) )
    ORDER BY lm.ArrivedAt ASC, l.Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
