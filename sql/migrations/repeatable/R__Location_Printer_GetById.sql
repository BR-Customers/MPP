-- ============================================================
-- Repeatable:  R__Location_Printer_GetById.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-30
-- Version:     2.0
-- Description: Resolve one Printer Location (DefId 16) by its own Id, with the
--   endpoint it is ACTUALLY dialled at. Unlike Terminal_GetPrinter (TOP 1 child
--   of a terminal), this addresses a SPECIFIC printer -- used to derive a
--   shipping-label dispatch endpoint from a printer id (printer-cards) and by
--   the Config Tool's Test printer action.
--   Read proc: one row, or empty set when the id is not an active Printer.
--
--   v2.0: the Endpoint column is now RESOLVED through
--   Location.ufn_PrinterEndpoint. For ConnectionKind = 'UsbBridge' it derives
--   from the PARENT TERMINAL's IpAddress plus port 9100 (spec section 8.1);
--   every other kind returns the stored value untouched, which is why the three
--   live Networked printers are unaffected. Resolving HERE rather than in Python
--   is what keeps every caller correct with no edit -- they were already asking
--   SQL for an endpoint. StoredEndpoint / TerminalIpAddress / EndpointSource are
--   added for commissioning diagnosis: without them a derived endpoint names a
--   host that appears nowhere on the printer row.
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
        e.Ep                AS Endpoint,
        mdv.AttributeValue  AS Model,
        ckv.AttributeValue  AS ConnectionKind,
        epv.AttributeValue  AS StoredEndpoint,
        tipv.AttributeValue AS TerminalIpAddress,
        CASE WHEN e.Ep IS NULL          THEN N'unresolved'
             WHEN k.Kind = N'UsbBridge' THEN N'derived-terminal-ip'
             ELSE N'stored' END          AS EndpointSource
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
    -- The parent Terminal (DefId 7). A DEPRECATED parent contributes no IpAddress,
    -- so a bridge printer under a retired terminal resolves to NULL and is reported
    -- unresolved rather than silently dialling a machine nobody runs any more.
    LEFT JOIN Location.Location t
        ON t.Id = p.ParentLocationId AND t.LocationTypeDefinitionId = 7 AND t.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttributeDefinition tipd
        ON tipd.LocationTypeDefinitionId = 7 AND tipd.AttributeName = N'IpAddress' AND tipd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute tipv ON tipv.LocationId = t.Id AND tipv.LocationAttributeDefinitionId = tipd.Id
    -- Compute the kind and the endpoint ONCE, so EndpointSource cannot disagree
    -- with Endpoint.
    CROSS APPLY (SELECT Kind = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ckv.AttributeValue, N''))), N''), N'Networked')) k
    CROSS APPLY (SELECT Ep = Location.ufn_PrinterEndpoint(k.Kind, epv.AttributeValue, tipv.AttributeValue)) e
    WHERE p.Id = @PrinterLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL;
END;
GO
