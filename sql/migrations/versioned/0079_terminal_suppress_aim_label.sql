-- ============================================================
-- Migration:   0079_terminal_suppress_aim_label.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-11
-- Description: Per-terminal shadow completion for the parallel run beside the
--              legacy MES.
--
--              WHY. While the legacy app still labels and reports containers,
--              an MES container completion must not claim an AIM shipper ID or
--              print a Honda label -- that would be a second serial and a
--              second label for a box legacy already labelled. But the MES must
--              still complete the box so its trays, finished-good LOTs and
--              counts keep pace. Before this, Lots.Container_Complete could
--              only do both or neither: with an empty pool it refused, and the
--              next PLC tray was then rejected as "Container is full".
--
--              WHAT. ONE Location.LocationAttributeDefinition row on LTD 7
--              (Terminal): 'SuppressAimAndLabel' (BIT, default '0'). A data
--              insert into the polymorphic location model, not DDL -- mirrors
--              0058 (CrtEnabled). Set per terminal in the Config Tool's Plant
--              Hierarchy attribute panel. An absent attribute reads as '0'.
--              Lots.Container_Complete v1.2 honours it: no pool check, no AIM
--              claim, no ShippingLabel row; the container still completes and
--              closes its finished-good LOTs.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0079_terminal_suppress_aim_label')
BEGIN PRINT 'Migration 0079 already applied -- skipping.'; RETURN; END
GO

IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'SuppressAimAndLabel' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'SuppressAimAndLabel', N'BIT', 0, N'0', NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'Parallel run: containers completed at this terminal claim no AIM shipper ID and print no shipping label. The legacy system labels and reports them.');
GO

-- Guarded like 0058: the top-of-file RETURN only exits its OWN batch.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0079_terminal_suppress_aim_label')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0079_terminal_suppress_aim_label',
            N'Location.LocationAttributeDefinition row: SuppressAimAndLabel (BIT) on LTD 7 (Terminal). Container_Complete v1.2 skips the AIM claim + ShippingLabel when set.');
GO
PRINT 'Migration 0079 (terminal_suppress_aim_label) applied.';
GO
