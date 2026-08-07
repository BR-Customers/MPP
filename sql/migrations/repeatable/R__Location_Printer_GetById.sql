-- ============================================================
-- Repeatable:  R__Location_Printer_GetById.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-06
-- Version:     1.0
-- Description: Resolve one Printer Location (DefId 16) by its own Id + its
--   Endpoint/Model/ConnectionKind attribute values. Unlike Terminal_GetPrinter
--   (TOP 1 child of a terminal), this addresses a SPECIFIC printer -- used to
--   derive a shipping-label dispatch endpoint from a printer id (printer-cards).
--   Read proc: one row, or empty set when the id is not an active Printer.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Printer_GetById
    @PrinterLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        p.Id                AS LocationId,
        p.Code              AS Code,
        p.Name              AS Name,
        epv.AttributeValue  AS Endpoint,
        mdv.AttributeValue  AS Model,
        ckv.AttributeValue  AS ConnectionKind
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition mdd
        ON mdd.LocationTypeDefinitionId = 16 AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute mdv ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    WHERE p.Id = @PrinterLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL;
END;
GO
