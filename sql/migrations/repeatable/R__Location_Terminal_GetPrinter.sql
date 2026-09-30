-- ============================================================
-- Repeatable:  R__Location_Terminal_GetPrinter.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-30
-- Version:     2.0
-- Description: The printer a terminal prints to: TOP 1 active child Printer
--   (DefId 16) of the given terminal, ordered by SortOrder then Id.
--   Read proc: one row, or an empty set when the terminal has no printer --
--   which is the normal, expected state for die-cast, trim and every IN
--   terminal, and is what makes LotLabel's fail-fast message honest.
--
--   v2.0: the Endpoint column is now RESOLVED through
--   Location.ufn_PrinterEndpoint. For ConnectionKind = 'UsbBridge' it derives
--   from this terminal's own IpAddress plus port 9100 (spec section 8.1); every
--   other kind returns the stored value untouched. ConnectionKind is now
--   projected (the other two printer reads already did), alongside
--   StoredEndpoint / TerminalIpAddress / EndpointSource for commissioning
--   diagnosis. Resolving HERE is what leaves BlueRidge.Location.Terminal
--   .getPrinter, LotLabel._dispatchAfterRender and ShippingDispatcher
--   ._resolveEndpoint correct with no edit at all.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetPrinter
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
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
    INNER JOIN Location.LocationTypeDefinition def ON def.Id = p.LocationTypeDefinitionId
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = def.Id AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv
        ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition mdd
        ON mdd.LocationTypeDefinitionId = def.Id AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute mdv
        ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = def.Id AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv
        ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    -- The terminal IS the parameter here, so the IpAddress lookup is direct.
    LEFT JOIN Location.LocationAttributeDefinition tipd
        ON tipd.LocationTypeDefinitionId = 7 AND tipd.AttributeName = N'IpAddress' AND tipd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute tipv
        ON tipv.LocationId = @TerminalLocationId AND tipv.LocationAttributeDefinitionId = tipd.Id
    CROSS APPLY (SELECT Kind = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ckv.AttributeValue, N''))), N''), N'Networked')) k
    CROSS APPLY (SELECT Ep = Location.ufn_PrinterEndpoint(k.Kind, epv.AttributeValue, tipv.AttributeValue)) e
    WHERE p.ParentLocationId = @TerminalLocationId
      AND def.Name = N'Printer'
      AND p.DeprecatedAt IS NULL
    ORDER BY p.SortOrder, p.Id;
END;
GO
