-- ============================================================
-- Repeatable:  R__Lots_Lot_Get.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-10
-- Version:     1.1
-- Description: Returns a single LOT row by @LotId or @LotName (Id wins if
--              both supplied). Returns the materialized B5 quantities
--              (TotalInProcess / InventoryAvailable) directly from Lots.Lot.
--              Empty result set = not found (FDS-11-011 read-proc convention;
--              no OUTPUT params, one result set). Read-only, no audit.
--
-- Change Log:
--   1.1 (2026-09-10) Cavity alpha code (0076): the cavity column AND its
--       result alias rename together -- tc.CavityNumber AS ToolCavityNumber
--       becomes tc.CavityCode AS ToolCavityCode. Renaming only the column
--       would leave every consumer of the alias rendering a blank cell with
--       no error at all.
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
        l.BomId,
        l.CreatedByUserId,
        l.CreatedAtTerminalId,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        CAST(l.UpdatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS UpdatedAt,
        l.UpdatedByUserId,
        l.RowVersion,
        -- resolved display fields (read-side convenience)
        i.PartNumber       AS ItemPartNumber,
        ot.Code            AS LotOriginTypeCode,
        sc.Code            AS LotStatusCode,
        sc.Name            AS LotStatusName,
        loc.Name           AS CurrentLocationName,
        t.Code             AS ToolCode,
        tc.CavityCode      AS ToolCavityCode,
        bom.VersionNumber  AS BomVersionNumber
    FROM Lots.Lot l
    INNER JOIN Parts.Item            i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotOriginType    ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Lots.LotStatusCode    sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Location.Location     loc ON loc.Id = l.CurrentLocationId
    LEFT  JOIN Tools.Tool            t   ON t.Id   = l.ToolId
    LEFT  JOIN Tools.ToolCavity      tc  ON tc.Id  = l.ToolCavityId
    LEFT  JOIN Parts.Bom             bom ON bom.Id = l.BomId
    WHERE (@LotId IS NOT NULL AND l.Id = @LotId)
       OR (@LotId IS NULL AND @LotName IS NOT NULL AND l.LotName = @LotName);
END;
GO
