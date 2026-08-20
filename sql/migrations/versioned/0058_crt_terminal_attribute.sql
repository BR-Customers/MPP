-- ============================================================
-- Migration: 0058_crt_terminal_attribute.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-14
-- Description: Controlled Run Tag capability on an assembly-out terminal.
--   Adds ONE Location.LocationAttributeDefinition row (LTD 7 = Terminal) --
--   a data insert into the existing polymorphic location model, NOT DDL.
--   Mirrors 0041, which added CurrentClosureMethod and VisionAppUrl the same way.
--
--   '0' / '1' like HasBarcodeScanner. An absent attribute reads as '0'.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0058_crt_terminal_attribute')
BEGIN PRINT 'Migration 0058 already applied -- skipping.'; RETURN; END
GO

IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'CrtEnabled', N'NVARCHAR', 0, N'0', NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'Controlled Run Tag active at this assembly-out terminal: containers complete pending a second-person validation before their AIM Shipper ID is posted.');
GO

-- Guarded like 0053/0054: the top-of-file RETURN only exits its OWN batch, so after
-- the next GO the remaining batches run regardless.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0058_crt_terminal_attribute')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0058_crt_terminal_attribute', N'Location.LocationAttributeDefinition row: CrtEnabled on LTD 7 (Terminal).');
GO
PRINT 'Migration 0058 (crt_terminal_attribute) applied.';
GO
