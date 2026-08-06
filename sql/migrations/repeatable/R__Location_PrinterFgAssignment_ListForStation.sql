-- ============================================================
-- Repeatable:  R__Location_PrinterFgAssignment_ListForStation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-06
-- Version:     1.0
-- Description: One row per active child Printer (DefId 16) of a station terminal,
--   LEFT-joined to its FG assignment (unassigned printers appear with NULLs) +
--   the printer's Endpoint/ConnectionKind. Drives the printer-card panel. Ordered
--   by the assignment SortOrder then printer Id. Empty set = no child printers.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.PrinterFgAssignment_ListForStation
    @StationTerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        p.Id                AS PrinterLocationId,
        p.Code              AS PrinterCode,
        p.Name              AS PrinterName,
        epv.AttributeValue  AS Endpoint,
        ckv.AttributeValue  AS ConnectionKind,
        pfa.ItemId          AS AssignedItemId,
        i.PartNumber        AS PartNumber,
        i.Description        AS Description,
        ISNULL(pfa.SortOrder, p.SortOrder) AS SortOrder
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    LEFT JOIN Location.PrinterFgAssignment pfa ON pfa.PrinterLocationId = p.Id
    LEFT JOIN Parts.Item i ON i.Id = pfa.ItemId
    WHERE p.ParentLocationId = @StationTerminalLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL
    ORDER BY ISNULL(pfa.SortOrder, p.SortOrder), p.Id;
END;
GO
