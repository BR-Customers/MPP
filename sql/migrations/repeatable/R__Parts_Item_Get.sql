-- =============================================
-- Procedure:   Parts.Item_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.3
--
-- Description:
--   Returns a single Item row by Id joined to ItemType.Name and Uom.Code
--   for display. Empty result = not found.
--
-- Parameters:
--   @Id BIGINT - PK. Required.
--
-- Result set:
--   Zero or one Item row with joined ItemTypeName, UomCode, WeightUomCode.
--   CrtEnabled is APPENDED LAST and every new column SHALL be appended last:
--   the test suite captures this proc via a fixed-shape INSERT-EXEC, and a
--   column inserted mid-list aborts the whole test file with Msg 213 (which
--   surfaces as a runner ERROR, not a FAIL line).
--
-- Dependencies:
--   Tables: Parts.Item, Parts.ItemType, Parts.Uom
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: CountryOfOrigin exposed (OI-19)
--   2026-04-27 - 2.2 - OI-12 correction: MaxParts exposed (moved from ContainerConfig)
--   2026-08-20 - 2.3 - Part-scoped CRT (Task 8): CrtEnabled appended LAST so the
--                       Config Tool Item Master Identity checkbox can read it back.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        i.Id,
        i.ItemTypeId,
        it.Name               AS ItemTypeName,
        i.PartNumber,
        i.Description,
        i.MacolaPartNumber,
        i.DefaultSubLotQty,
        i.MaxLotSize,
        i.UomId,
        u.Code                AS UomCode,
        i.UnitWeight,
        i.WeightUomId,
        wu.Code               AS WeightUomCode,
        i.CountryOfOrigin,
        i.MaxParts,
        i.CreatedAt,
        i.UpdatedAt,
        i.CreatedByUserId,
        i.UpdatedByUserId,
        i.DeprecatedAt,
        i.CrtEnabled          -- APPEND-LAST: see Result set note above
    FROM Parts.Item i
    INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
    INNER JOIN Parts.Uom u       ON u.Id  = i.UomId
    LEFT  JOIN Parts.Uom wu      ON wu.Id = i.WeightUomId
    WHERE i.Id = @Id;
END;
GO
