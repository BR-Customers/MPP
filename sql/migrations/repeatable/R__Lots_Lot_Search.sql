-- ============================================================
-- Repeatable:  R__Lots_Lot_Search.sql
-- Version:     2.0 (2026-11-04, container-as-LOT spec
--              docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md
--              8.2) - built for year-scale LOT volume:
--                * an EXACT LotName match is always returned, whatever its age
--                  (a seek on UQ_Lot_LotName);
--                * every other match -- part of a LOT name, part number,
--                  vendor LOT -- looks at the last 90 days (a CreatedAt range on
--                  the heap; the clustered index this was first measured with
--                  is NOT part of this change)
--                  unless @IncludeOlder = 1 ("Search older");
--                * part numbers resolve through Parts.Item first (a small table),
--                  then Lot.ItemId;
--                * COUNT(*) OVER() is gone (it counted every match on every call):
--                  TotalCount = the rows returned, HasMore = there were more than
--                  @LimitRows (last column, new). Callers that showed "N of M"
--                  show "100+" when HasMore = 1.
--              A year of tray-per-LOT volume took this proc 7-25 s per call.
-- Description: READ proc backing LOT Search. Free-text over LotName /
--              VendorLotNumber / Item.PartNumber + optional Status + Origin
--              filters. One result set; recency-ordered; TOP (@LimitRows).
--              No status row. (Serial/Shipper search deferred -- Phase 3/6 tables.)
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_Search
    @Query           NVARCHAR(100) = NULL,
    @LotStatusId     BIGINT        = NULL,
    @LotOriginTypeId BIGINT        = NULL,
    @LimitRows       INT           = 100,
    @IncludeOlder    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;
    DECLARE @Raw NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@Query)), N'');
    DECLARE @Q NVARCHAR(120) = N'%' + @Raw + N'%';
    DECLARE @WindowFrom DATETIME2(3) = CASE WHEN ISNULL(@IncludeOlder, 0) = 1 THEN NULL
                                            ELSE DATEADD(DAY, -90, SYSUTCDATETIME()) END;

    DECLARE @Cand TABLE (Id BIGINT NOT NULL PRIMARY KEY);

    -- 1. exact LOT name, any age
    IF @Raw IS NOT NULL
        INSERT INTO @Cand (Id)
        SELECT l.Id FROM Lots.Lot l
        WHERE l.LotName = @Raw
          AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
          AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId);

    -- 2. everything else, newest first, inside the window
    DECLARE @Items TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    IF @Raw IS NOT NULL
        INSERT INTO @Items (Id) SELECT i.Id FROM Parts.Item i WHERE i.PartNumber LIKE @Q;

    -- An exact LOT name answers alone: the operator scanned or typed a whole LOT
    -- number, so the windowed partial-match scan is skipped.
    IF NOT EXISTS (SELECT 1 FROM @Cand)
    INSERT INTO @Cand (Id)
    SELECT TOP (@LimitRows + 1) l.Id
    FROM Lots.Lot l
    WHERE (@WindowFrom IS NULL OR l.CreatedAt >= @WindowFrom)
      AND (@Raw IS NULL
           OR l.LotName LIKE @Q
           OR l.VendorLotNumber LIKE @Q
           OR l.ItemId IN (SELECT Id FROM @Items))
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
      AND NOT EXISTS (SELECT 1 FROM @Cand x WHERE x.Id = l.Id)
    ORDER BY l.CreatedAt DESC, l.Id DESC
    OPTION (RECOMPILE);   -- @Items / filters are known per call

    DECLARE @Found INT = (SELECT COUNT(*) FROM @Cand);
    DECLARE @HasMore BIT = CASE WHEN @Found > @LimitRows THEN 1 ELSE 0 END;
    DECLARE @Returned INT = CASE WHEN @Found > @LimitRows THEN @LimitRows ELSE @Found END;

    SELECT TOP (@LimitRows)
        l.Id, l.LotName, l.ItemId, l.LotOriginTypeId, l.LotStatusId, l.PieceCount,
        l.VendorLotNumber, l.CurrentLocationId, CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        i.PartNumber  AS ItemPartNumber,
        sc.Code       AS LotStatusCode,
        ot.Code       AS LotOriginTypeCode,
        loc.Name      AS CurrentLocationName,
        lastop.OperationName AS LastOperationName,
        @Returned     AS TotalCount,
        @HasMore      AS HasMore
    FROM @Cand c
    INNER JOIN Lots.Lot           l   ON l.Id   = c.Id
    INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Lots.LotOriginType ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
    OUTER APPLY (
        SELECT TOP (1) oty.Name AS OperationName
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot2.OperationTypeId
        WHERE pe.LotId = l.Id
        ORDER BY pe.EventAt DESC, pe.Id DESC
    ) lastop
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END;
GO
