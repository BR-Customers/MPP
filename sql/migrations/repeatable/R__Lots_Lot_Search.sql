-- ============================================================
-- Repeatable:  R__Lots_Lot_Search.sql
-- Description: READ proc backing LOT Search. Free-text LIKE over LotName /
--              VendorLotNumber / Item.PartNumber + optional Status + Origin
--              filters. One result set; recency-ordered; TOP (@LimitRows).
--              No status row. (Serial/Shipper search deferred -- Phase 3/6 tables.)
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_Search
    @Query           NVARCHAR(100) = NULL,
    @LotStatusId     BIGINT        = NULL,
    @LotOriginTypeId BIGINT        = NULL,
    @LimitRows       INT           = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;
    DECLARE @Q NVARCHAR(120) = CASE WHEN @Query IS NULL OR LTRIM(RTRIM(@Query)) = N''
                                    THEN NULL ELSE N'%' + LTRIM(RTRIM(@Query)) + N'%' END;
    SELECT TOP (@LimitRows)
        l.Id, l.LotName, l.ItemId, l.LotOriginTypeId, l.LotStatusId, l.PieceCount,
        l.VendorLotNumber, l.CurrentLocationId, CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        i.PartNumber  AS ItemPartNumber,
        sc.Code       AS LotStatusCode,
        ot.Code       AS LotOriginTypeCode,
        loc.Name      AS CurrentLocationName,
        lastop.OperationName AS LastOperationName,
        COUNT(*) OVER() AS TotalCount
    FROM Lots.Lot l
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
    WHERE (@Q IS NULL OR l.LotName LIKE @Q OR l.VendorLotNumber LIKE @Q OR i.PartNumber LIKE @Q)
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END;
GO
