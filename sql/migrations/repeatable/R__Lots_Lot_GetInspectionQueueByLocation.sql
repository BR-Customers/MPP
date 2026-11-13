-- ============================================================
-- Repeatable:  R__Lots_Lot_GetInspectionQueueByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-13
-- Version:     1.1
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
--
--              v1.1 (2026-11-13, stored-procedure review -- same query SHAPE as the one
--              behind the 2026-11-10 prod incident, notes/2026-11-10_prod-incident-
--              assembly-out-deadlock.md; no deadlock has been observed on THIS proc):
--              same rows, same order, no longer a heap scan. v1.0 OR'd the exact-location
--              and descendant cases in one predicate, aggregated ALL of Lots.LotMovement
--              per call, and ranked EVERY row of Quality.QualitySample
--              (ROW_NUMBER over the whole table) to find each LOT's latest result.
--              Now: locations resolved into @Locs; open received LOTs found by seek on
--              IX_Lot_NotClosed_Location (0118); the last movement and the latest
--              inspection are per-LOT seeks (CIX_LotMovement_LotMovedAt and
--              IX_QualitySample_LotId_SampledAt). "Latest" is unchanged: greatest
--              SampledAt, ties broken by greatest Id. A NULL @IncludeDescendants still
--              returns nothing (both v1.0 predicate arms were NULL).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetInspectionQueueByLocation
    @LocationId         BIGINT,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. The locations in scope: the station alone (@IncludeDescendants = 0) or it and
    --    every descendant (= 1). NULL matches neither, so @Locs stays empty.
    DECLARE @Locs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    IF @IncludeDescendants = 1
    BEGIN
        ;WITH Descendants AS (
            SELECT @LocationId AS Id
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        INSERT INTO @Locs (Id) SELECT Id FROM Descendants WHERE Id IS NOT NULL
        OPTION (MAXRECURSION 8);
    END
    ELSE IF @IncludeDescendants = 0
        INSERT INTO @Locs (Id) SELECT @LocationId WHERE @LocationId IS NOT NULL;

    -- 2. Open received-origin LOTs in scope. Only Closed is excluded (v1.0 behaviour).
    --    'LotStatusId <> 4' repeats IX_Lot_NotClosed_Location's filter (0118) so the
    --    optimiser seeks it; the code-table join is what actually decides.
    --    Every column the result needs is read HERE, once per LOT (header, Item, last
    --    movement, latest inspection), so the final SELECT reads only @Lots and never
    --    re-joins the Lots.Lot heap. "Latest inspection" = greatest SampledAt, then
    --    greatest Id -- exactly the v1.0 ROW_NUMBER() ... ORDER BY SampledAt DESC,
    --    Id DESC, rn = 1 -- as a per-LOT TOP 1 seek on IX_QualitySample_LotId_SampledAt.
    --    The last movement is a per-LOT seek on CIX_LotMovement_LotMovedAt.
    DECLARE @Lots TABLE (LotId BIGINT NOT NULL PRIMARY KEY, LotName NVARCHAR(50) NOT NULL, ItemId BIGINT NOT NULL,
                         ItemPartNumber NVARCHAR(50) NOT NULL, ItemDescription NVARCHAR(500) NULL,
                         PieceCount INT NOT NULL, VendorLotNumber NVARCHAR(50) NULL,
                         LotStatusId BIGINT NOT NULL, LotStatusCode NVARCHAR(20) NOT NULL,
                         LatestInspectionResult NVARCHAR(20) NULL, LatestSampledAtUtc DATETIME2(3) NULL,
                         ArrivedAtUtc DATETIME2(3) NULL);
    INSERT INTO @Lots (LotId, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, VendorLotNumber,
                       LotStatusId, LotStatusCode, LatestInspectionResult, LatestSampledAtUtc, ArrivedAtUtc)
    SELECT l.Id, l.LotName, l.ItemId, i.PartNumber, i.Description, l.PieceCount, l.VendorLotNumber,
           l.LotStatusId, sc.Code, irc.Code, li.SampledAt, lm.ArrivedAt
    FROM @Locs x
    INNER JOIN Lots.Lot l            ON l.CurrentLocationId = x.Id
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
    INNER JOIN Lots.LotOriginType ot ON ot.Id = l.LotOriginTypeId AND ot.Code IN (N'Received', N'ReceivedOffsite')
    INNER JOIN Parts.Item i          ON i.Id = l.ItemId
    OUTER APPLY (SELECT MAX(m.MovedAt) AS ArrivedAt
                 FROM Lots.LotMovement m WHERE m.LotId = l.Id) lm
    OUTER APPLY (SELECT TOP (1) qs.InspectionResultCodeId, qs.SampledAt
                 FROM Quality.QualitySample qs
                 WHERE qs.LotId = l.Id
                 ORDER BY qs.SampledAt DESC, qs.Id DESC) li
    LEFT  JOIN Quality.InspectionResultCode irc ON irc.Id = li.InspectionResultCodeId
    WHERE l.LotStatusId <> 4;

    -- 3. Result (ET at the read boundary), arrival order.
    SELECT
        e.LotId AS Id, e.LotName, e.ItemId,
        e.ItemPartNumber,
        e.ItemDescription,
        e.PieceCount, e.VendorLotNumber,
        e.LotStatusId, e.LotStatusCode,
        e.LatestInspectionResult,
        CAST(e.LatestSampledAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LatestSampledAt,
        CAST(e.ArrivedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAt
    FROM @Lots e
    ORDER BY e.ArrivedAtUtc ASC, e.LotId ASC;
END;
GO
