-- ============================================================
-- Repeatable:  R__Location_PrinterFgAssignment_ListForStation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-30
-- Version:     2.0
-- Description: One row per active child Printer (DefId 16) of a station terminal,
--   with the finished good assigned to that printer card, if any. Drives the
--   plant-floor PrinterCard strip. Read proc: zero or more rows.
--
--   v2.0: the Endpoint column is now RESOLVED through
--   Location.ufn_PrinterEndpoint. For ConnectionKind = 'UsbBridge' it derives
--   from the station terminal's IpAddress plus port 9100 (spec section 8.1);
--   every other kind returns the stored value untouched. Because the resolved
--   value lands in the column PrinterCard's params.endpoint already binds to,
--   that component starts probing UsbBridge cards with NO changes.
--   StoredEndpoint / TerminalIpAddress / EndpointSource are added for
--   commissioning diagnosis.
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
        e.Ep                AS Endpoint,
        ckv.AttributeValue  AS ConnectionKind,
        pfa.ItemId          AS AssignedItemId,
        i.PartNumber        AS PartNumber,
        i.Description       AS Description,
        ISNULL(pfa.SortOrder, p.SortOrder) AS SortOrder,
        epv.AttributeValue  AS StoredEndpoint,
        tipv.AttributeValue AS TerminalIpAddress,
        CASE WHEN e.Ep IS NULL          THEN N'unresolved'
             WHEN k.Kind = N'UsbBridge' THEN N'derived-terminal-ip'
             ELSE N'stored' END          AS EndpointSource
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    LEFT JOIN Location.LocationAttributeDefinition tipd
        ON tipd.LocationTypeDefinitionId = 7 AND tipd.AttributeName = N'IpAddress' AND tipd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute tipv
        ON tipv.LocationId = @StationTerminalLocationId AND tipv.LocationAttributeDefinitionId = tipd.Id
    LEFT JOIN Location.PrinterFgAssignment pfa ON pfa.PrinterLocationId = p.Id
    LEFT JOIN Parts.Item i ON i.Id = pfa.ItemId
    CROSS APPLY (SELECT Kind = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ckv.AttributeValue, N''))), N''), N'Networked')) k
    CROSS APPLY (SELECT Ep = Location.ufn_PrinterEndpoint(k.Kind, epv.AttributeValue, tipv.AttributeValue)) e
    WHERE p.ParentLocationId = @StationTerminalLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL
    ORDER BY ISNULL(pfa.SortOrder, p.SortOrder), p.Id;
END;
GO
