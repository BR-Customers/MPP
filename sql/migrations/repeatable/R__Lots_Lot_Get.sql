-- ============================================================
-- Repeatable:  R__Lots_Lot_Get.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Returns a single LOT row by @LotId or @LotName (Id wins if
--              both supplied). Returns the materialized B5 quantities
--              (TotalInProcess / InventoryAvailable) directly from Lots.Lot.
--              Empty result set = not found (FDS-11-011 read-proc convention;
--              no OUTPUT params, one result set). Read-only, no audit.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_Get
    @LotId   BIGINT       = NULL,
    @LotName NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.Id,
        l.LotName,
        l.ItemId,
        l.LotOriginTypeId,
        l.LotStatusId,
        l.PieceCount,
        l.MaxPieceCount,
        l.Weight,
        l.WeightUomId,
        l.ToolId,
        l.ToolCavityId,
        l.VendorLotNumber,
        l.MinSerialNumber,
        l.MaxSerialNumber,
        l.ParentLotId,
        l.CurrentLocationId,
        l.CrtActive,
        l.TotalInProcess,
        l.InventoryAvailable,
        l.CreatedByUserId,
        l.CreatedAtTerminalId,
        l.CreatedAt,
        l.UpdatedAt,
        l.UpdatedByUserId,
        l.RowVersion,
        -- resolved display fields (read-side convenience)
        i.PartNumber       AS ItemPartNumber,
        ot.Code            AS LotOriginTypeCode,
        sc.Code            AS LotStatusCode,
        sc.Name            AS LotStatusName,
        loc.Name           AS CurrentLocationName,
        t.Code             AS ToolCode,
        tc.CavityNumber    AS ToolCavityNumber
    FROM Lots.Lot l
    INNER JOIN Parts.Item            i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotOriginType    ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Lots.LotStatusCode    sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Location.Location     loc ON loc.Id = l.CurrentLocationId
    LEFT  JOIN Tools.Tool            t   ON t.Id   = l.ToolId
    LEFT  JOIN Tools.ToolCavity      tc  ON tc.Id  = l.ToolCavityId
    WHERE (@LotId IS NOT NULL AND l.Id = @LotId)
       OR (@LotId IS NULL AND @LotName IS NOT NULL AND l.LotName = @LotName);
END;
GO
