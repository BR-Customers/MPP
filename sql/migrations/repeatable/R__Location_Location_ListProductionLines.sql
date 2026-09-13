-- =============================================
-- Procedure:   Location.Location_ListProductionLines
-- Author:      Blue Ridge Automation
-- Created:     2026-09-12
-- Version:     1.0
--
-- Description:
--   Active Production Lines, for the inventory cutover scan's LINE picker.
--
--   A "line" here is Work Center tier + the ProductionLine definition
--   specifically -- NOT Work Center tier generally, which would also return
--   the Inspection Line, and emphatically NOT Cell tier, which is where the
--   134 Terminal/Printer locations live.
--
--   That distinction is the whole point of this proc. The cutover scan first
--   shipped bound to getCellsForDropdown, which offered the operator a list of
--   TERMINALS (MA1-5GOF-ASER) instead of the LINE they sit under (MA1-5GOF).
--   Picking a terminal would have written every scanned basket's
--   CurrentLocationId to a Cell, while the whole M&A model is line-resident:
--   the WIP queues match LOTs AT the line, and Location_GetStockDestination
--   resolves ISNULL(DefaultStockLocationId, <the line>). Stock scanned onto a
--   terminal would have gone quietly missing from the queues it belongs in.
--
--   Deliberately excludes the Inspection Line: cutover is line-by-line across
--   M&A. If inspection stock ever needs scanning in, widen this proc rather
--   than pointing the picker back at a generic tier read.
--
-- Parameters:
--   (none)
--
-- Result set:
--   Id, Code, Name, ParentLocationId, SortOrder. Ordered by Code ASC so the
--   picker reads in plant order (MA1-... before MA2-...).
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition,
--           Location.LocationType
--
-- Change Log:
--   2026-09-12 - 1.0 - Initial version (inventory cutover scan LINE picker)
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_ListProductionLines
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        loc.Id,
        loc.Code,
        loc.Name,
        loc.ParentLocationId,
        loc.SortOrder
    FROM Location.Location loc
    INNER JOIN Location.LocationTypeDefinition ltd
        ON ltd.Id = loc.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt
        ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code  = N'WorkCenter'
      AND ltd.Code = N'ProductionLine'
      AND loc.DeprecatedAt IS NULL
    ORDER BY loc.Code;
END;
GO
