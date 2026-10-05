/* ============================================================
   Printer endpoint will not resolve -- onsite diagnosis, 2026-10-05
   Terminal: MA2-6MACH-AOUT3 (Assembly Out)   Printer: MA2-6MACH-AOUT3-P1 (P - 037)

   READ-ONLY. Run against the database the failures are in.
   Work top to bottom; the FIRST section that looks wrong is the answer.
   ============================================================ */

SET NOCOUNT ON;

DECLARE @TerminalCode NVARCHAR(100) = N'MA2-6MACH-AOUT3';
DECLARE @TerminalId BIGINT = (SELECT Id FROM Location.Location
                              WHERE Code = @TerminalCode AND DeprecatedAt IS NULL);

SELECT TerminalCode = @TerminalCode, TerminalId = @TerminalId;   -- NULL here = wrong code


/* [1] IS THE RELEASE ACTUALLY DEPLOYED?
   All four must be present. If ufn_PrinterEndpoint is missing, nothing below
   can derive and THAT is the whole answer. */
SELECT
    Applied            = (SELECT COUNT(*) FROM dbo.SchemaVersion),
    Highest            = (SELECT MAX(MigrationId) FROM dbo.SchemaVersion),   -- expect 0102_*
    ufn_PrinterEndpoint= ISNULL(CAST(OBJECT_ID('Location.ufn_PrinterEndpoint') AS varchar(20)), 'MISSING'),
    Terminal_GetPrinter_Modified = (SELECT CONVERT(varchar(19), modify_date, 120)
                                    FROM sys.objects WHERE object_id = OBJECT_ID('Location.Terminal_GetPrinter')),
    Printer_GetById_Modified     = (SELECT CONVERT(varchar(19), modify_date, 120)
                                    FROM sys.objects WHERE object_id = OBJECT_ID('Location.Printer_GetById'));


/* [2] THE RAW STORED FACTS -- what is actually in the attribute tables.
   Expect: Terminal IpAddress = 172.17.20.142, ConnectionKind = UsbBridge.
   A blank/absent IpAddress row is the common commissioning miss. */
SELECT
    Owner     = o.Code,
    OwnerType = d.Name,
    Attribute = ad.AttributeName,
    Value     = a.AttributeValue,
    ValueLen  = LEN(a.AttributeValue),          -- 0 or NULL matters
    HasRow    = CASE WHEN a.Id IS NULL THEN 'NO ATTRIBUTE ROW' ELSE 'row present' END
FROM Location.Location o
INNER JOIN Location.LocationTypeDefinition d ON d.Id = o.LocationTypeDefinitionId
INNER JOIN Location.LocationAttributeDefinition ad
        ON ad.LocationTypeDefinitionId = d.Id AND ad.DeprecatedAt IS NULL
LEFT  JOIN Location.LocationAttribute a
        ON a.LocationId = o.Id AND a.LocationAttributeDefinitionId = ad.Id
WHERE (o.Id = @TerminalId OR o.ParentLocationId = @TerminalId)
  AND ad.AttributeName IN (N'IpAddress', N'Endpoint', N'ConnectionKind', N'Model', N'DefaultPrinter')
ORDER BY d.Name, o.Code, ad.AttributeName;


/* [3] IS THE PRINTER ACTUALLY A CHILD OF THAT TERMINAL, AND TYPED 'Printer'?
   Terminal_GetPrinter matches on ParentLocationId + def.Name = 'Printer' + not deprecated.
   An empty result here is EXACTLY the EndpointUnresolved cause. */
SELECT
    PrinterId   = p.Id,
    PrinterCode = p.Code,
    ParentId    = p.ParentLocationId,
    TypeDefId   = p.LocationTypeDefinitionId,
    TypeName    = def.Name,                      -- must be exactly 'Printer'
    Deprecated  = p.DeprecatedAt,                -- must be NULL
    SortOrder   = p.SortOrder
FROM Location.Location p
INNER JOIN Location.LocationTypeDefinition def ON def.Id = p.LocationTypeDefinitionId
WHERE p.ParentLocationId = @TerminalId;


/* [4] THE DERIVATION, STAGE BY STAGE -- where the NULL enters. */
DECLARE @Ck  NVARCHAR(50)  = (SELECT TOP 1 a.AttributeValue FROM Location.Location p
    INNER JOIN Location.LocationAttributeDefinition ad ON ad.LocationTypeDefinitionId = p.LocationTypeDefinitionId
                                                      AND ad.AttributeName = N'ConnectionKind' AND ad.DeprecatedAt IS NULL
    LEFT  JOIN Location.LocationAttribute a ON a.LocationId = p.Id AND a.LocationAttributeDefinitionId = ad.Id
    WHERE p.ParentLocationId = @TerminalId ORDER BY p.SortOrder, p.Id);
DECLARE @Stored NVARCHAR(255) = (SELECT TOP 1 a.AttributeValue FROM Location.Location p
    INNER JOIN Location.LocationAttributeDefinition ad ON ad.LocationTypeDefinitionId = p.LocationTypeDefinitionId
                                                      AND ad.AttributeName = N'Endpoint' AND ad.DeprecatedAt IS NULL
    LEFT  JOIN Location.LocationAttribute a ON a.LocationId = p.Id AND a.LocationAttributeDefinitionId = ad.Id
    WHERE p.ParentLocationId = @TerminalId ORDER BY p.SortOrder, p.Id);
DECLARE @Tip NVARCHAR(64) = (SELECT a.AttributeValue FROM Location.LocationAttributeDefinition ad
    LEFT JOIN Location.LocationAttribute a ON a.LocationId = @TerminalId AND a.LocationAttributeDefinitionId = ad.Id
    WHERE ad.LocationTypeDefinitionId = 7 AND ad.AttributeName = N'IpAddress' AND ad.DeprecatedAt IS NULL);

SELECT
    ConnectionKind = ISNULL(@Ck, '(none)'),
    StoredEndpoint = ISNULL(@Stored, '(none)'),
    TerminalIp_Raw = ISNULL(@Tip, '(none)'),
    TerminalIp_Normalized = ISNULL(Location.ufn_NormalizeIpAddress(@Tip), '(NULL)'),
    DerivedEndpoint       = ISNULL(Location.ufn_PrinterEndpoint(@Ck, @Stored, @Tip), '(NULL <-- this is the failure)');


/* [5] THE ACTUAL PROCS THE GATEWAY CALLS.
   Endpoint must be non-NULL. EndpointSource tells you which path produced it. */
EXEC Location.Terminal_GetPrinter @TerminalLocationId = @TerminalId;

DECLARE @PrinterId BIGINT = (SELECT TOP 1 p.Id FROM Location.Location p
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = p.LocationTypeDefinitionId
    WHERE p.ParentLocationId = @TerminalId AND d.Name = N'Printer' AND p.DeprecatedAt IS NULL
    ORDER BY p.SortOrder, p.Id);
EXEC Location.Printer_GetById @PrinterLocationId = @PrinterId;


/* [6] WHICH TERMINAL DID THE FAILING SESSION THINK IT WAS AT?
   The dispatcher only reaches the terminal path when the caller passes a
   terminalLocationId. If the session fell back to the facility-wide terminal,
   that id is NOT this one and no printer will ever be found. */
SELECT TOP 20
    il.Id, il.LoggedAt, il.Description, il.ErrorCondition, il.ErrorDescription, il.RequestPayload
FROM Audit.InterfaceLog il
WHERE il.SystemName = N'Zebra' AND il.ErrorCondition = N'EndpointUnresolved'
ORDER BY il.Id DESC;
