-- ============================================================
-- Repeatable:  R__Lots_Lot_List.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Filterable LOT listing (admin / LOT-search screen). All
--              filters optional (NULL = no filter). @LimitRows caps the
--              rowset (default 100). Read-only, no audit. One result set
--              (FDS-11-011). Same materialized-quantity columns as Lot_Get.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_List
    @ItemId            BIGINT = NULL,
    @CurrentLocationId BIGINT = NULL,
    @LotStatusId       BIGINT = NULL,
    @LimitRows         INT    = 100
AS
BEGIN
    SET NOCOUNT ON;

    IF @LimitRows IS NULL OR @LimitRows < 1
        SET @LimitRows = 100;

    SELECT TOP (@LimitRows)
        l.Id,
        l.LotName,
        l.ItemId,
        l.LotOriginTypeId,
        l.LotStatusId,
        l.PieceCount,
        l.MaxPieceCount,
        l.ToolId,
        l.ToolCavityId,
        l.CurrentLocationId,
        l.CrtActive,
        l.TotalInProcess,
        l.InventoryAvailable,
        l.CreatedAt,
        i.PartNumber AS ItemPartNumber,
        sc.Code      AS LotStatusCode,
        loc.Name     AS CurrentLocationName
    FROM Lots.Lot l
    INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
    WHERE (@ItemId            IS NULL OR l.ItemId            = @ItemId)
      AND (@CurrentLocationId IS NULL OR l.CurrentLocationId = @CurrentLocationId)
      AND (@LotStatusId       IS NULL OR l.LotStatusId       = @LotStatusId)
    ORDER BY l.Id DESC;
END;
GO
