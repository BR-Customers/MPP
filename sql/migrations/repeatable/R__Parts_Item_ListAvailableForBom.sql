-- =============================================
-- Procedure:   Parts.Item_ListAvailableForBom
-- Author:      Blue Ridge Automation
-- Created:     2026-05-26
-- Version:     1.0
--
-- Description:
--   Returns active Parts.Item rows eligible to be added as BomLine
--   components of the given parent Item. Excludes:
--     - The parent Item itself (no self-reference)
--     - Deprecated Items
--     - Finished Goods (never BOM components per business rule)
--
--   Optional @SearchText applies a prefix match on PartNumber OR
--   substring match on Description.
--
--   Returned columns include the Item's default UomId/Code so the UI
--   can prepopulate the BomLine row's UOM dropdown on ChildItem pick.
--
-- Parameters:
--   @ParentItemId BIGINT             - Required.
--   @SearchText   NVARCHAR(50) = NULL - Optional filter.
--
-- Result set:
--   Id, PartNumber, Description, ItemTypeId, ItemTypeName,
--   DefaultUomId, DefaultUomCode
--   Ordered by PartNumber ASC.
--
-- Dependencies:
--   Tables: Parts.Item, Parts.ItemType, Parts.Uom
--
-- Change Log:
--   2026-05-26 - 1.0 - Initial.
--   2026-05-27 - 1.1 - Exclude Finished Goods (never valid as BOM
--                      components -- they ARE the BOM parent).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_ListAvailableForBom
    @ParentItemId BIGINT,
    @SearchText   NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Like NVARCHAR(55) = NULLIF(LTRIM(RTRIM(ISNULL(@SearchText, N''))), N'');

    SELECT
        i.Id,
        i.PartNumber,
        i.Description,
        i.ItemTypeId,
        it.Name        AS ItemTypeName,
        i.UomId        AS DefaultUomId,
        u.Code         AS DefaultUomCode
    FROM Parts.Item i
    INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
    INNER JOIN Parts.Uom u       ON u.Id  = i.UomId
    WHERE i.DeprecatedAt IS NULL
      AND i.Id <> @ParentItemId
      AND it.Name <> N'Finished Good'
      AND (
            @Like IS NULL
         OR i.PartNumber LIKE @Like + N'%'
         OR i.Description LIKE N'%' + @Like + N'%'
      )
    ORDER BY i.PartNumber ASC;
END;
GO
