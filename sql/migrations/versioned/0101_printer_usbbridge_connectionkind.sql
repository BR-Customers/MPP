-- ============================================================
-- Migration:   0101_printer_usbbridge_connectionkind.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-30
-- Description: A third ConnectionKind for Printer locations (LTD 16): UsbBridge.
--
--              WHY. MPP is going 100% USB-attached: 54 printers across 77
--              terminal PCs, each reached through the MesZebraBridge service
--              listening on TCP 9100 on the terminal PC itself. With every
--              printer USB attached, the bridge ALWAYS runs on the terminal, so
--              a bridge printer's endpoint host is by construction its parent
--              Terminal's IpAddress. There is no second address, so it is not
--              stored: 54 hand-entered addresses become zero, and the
--              port-omission trap (a bare '10.20.11.157' is silently
--              reclassified by LabelTransport's grammar as a Windows print-QUEUE
--              name) becomes unreachable because no human types the endpoint.
--
--              The Terminal IpAddress is set during commissioning, one terminal
--              at a time as a line is walked -- as of 2026-09-30, 17 of 77
--              terminals carry one and 47 of 54 printers sit under a terminal
--              with none. The PCs are statically addressed; the CONFIGURATION
--              catches up per visit. That sequencing is what makes derivation
--              correct here: the address is entered once, one step before
--              anything consumes it, so the terminal IP and the printer endpoint
--              cannot disagree because there is only one of them.
--              Spec: docs/superpowers/specs/
--              2026-09-29-zebra-bridge-service-and-print-traceability-design.md
--              sections 7, 8 and 8.1.
--
--              WHAT.
--              1. ConnectionKind's Description now names all three values. The
--                 ALLOWED-VALUE SET IS NOT CONSTRAINED IN SQL and this migration
--                 does not pretend otherwise: LocationAttributeDefinition has no
--                 allowed-values column, and LocationAttribute.AttributeValue is
--                 one NVARCHAR(255) column shared by every attribute of every
--                 location type, so a code table with an FK is not expressible
--                 without restructuring the polymorphic model. The dropdown in
--                 BlueRidge.Location.AttributeOptions is the only list, and it is
--                 authored allowCustomOptions = true. Location.ufn_PrinterEndpoint
--                 is written so an UNRECOGNISED kind falls to the stored-endpoint
--                 path rather than to a guess.
--              2. Endpoint.IsRequired 1 -> 0. A UsbBridge printer stores no
--                 endpoint, and Location.Location_SaveAll parses incoming values
--                 with NULLIF(LTRIM(RTRIM(..)), N''), so a blank Endpoint becomes
--                 NULL and the generic required-attribute check refuses the save
--                 with "Required attribute missing a value: Endpoint."
--                 Relaxing the flag alone would let a Networked printer save with
--                 NO address and fail silently at dispatch, so the requirement
--                 MOVES into Location_SaveAll v1.4, which can see the sibling
--                 ConnectionKind value. Apply that repeatable in the same window.
--
--              NOT DONE HERE. No existing printer row is re-kinded. The three
--              live Networked printers (172.17.20.228 / .229, both :9100) keep
--              their stored endpoints; their addresses are genuinely independent
--              of their terminals', which is precisely why the kinds stay
--              distinct instead of derivation being applied universally.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0101_printer_usbbridge_connectionkind')
BEGIN PRINT 'Migration 0101 already applied -- skipping.'; RETURN; END
GO

UPDATE Location.LocationAttributeDefinition
SET Description = N'Networked = stored host:port, TCP direct to a printer with its own NIC. Hardwired = stored Windows print-queue name, printed through the Gateway host. UsbBridge = NO endpoint stored; it derives from the parent Terminal IpAddress plus port 9100, where the MesZebraBridge service listens.'
WHERE LocationTypeDefinitionId = 16
  AND AttributeName = N'ConnectionKind'
  AND DeprecatedAt IS NULL;
GO

UPDATE Location.LocationAttributeDefinition
SET IsRequired  = 0,
    Description = N'Zebra print target - IP:port or print-queue name. Leave BLANK when ConnectionKind is UsbBridge: the endpoint derives from the parent Terminal IpAddress plus port 9100. Required for Networked and Hardwired, enforced by Location.Location_SaveAll.'
WHERE LocationTypeDefinitionId = 16
  AND AttributeName = N'Endpoint'
  AND DeprecatedAt IS NULL;
GO

-- Guarded like 0079: the top-of-file RETURN only exits its OWN batch.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0101_printer_usbbridge_connectionkind')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0101_printer_usbbridge_connectionkind',
            N'Printer (LTD 16): ConnectionKind description names the third value UsbBridge; Endpoint.IsRequired 1 -> 0 (the requirement moves to Location_SaveAll v1.4, conditional on ConnectionKind).');
GO
PRINT 'Migration 0101 (printer_usbbridge_connectionkind) applied.';
GO
