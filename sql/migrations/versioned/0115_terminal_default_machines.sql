-- ============================================================
-- Migration:   0115_terminal_default_machines.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-10-23
-- Description: Per-terminal default machines for the die cast press picker.
--
--              WHY. A die cast room carries several terminals beside its
--              presses. The press picker listed every press in the room, so
--              an operator could apply a LOT or a shift summary to a press
--              across the room as easily as to the one in front of them.
--              MPP wants a row of buttons for the presses this terminal is
--              placed to serve, plus a "show all" button so a terminal that
--              is down or crowded does not strand anybody.
--
--              WHAT. ONE Location.LocationAttributeDefinition row on LTD 7
--              (Terminal): 'DefaultMachines' (NVARCHAR, optional). The value
--              is a comma-separated list of Location.Id -- the equipment cells
--              this terminal shows by default. Ids, not codes, so renaming a
--              press code does not orphan the setting. Edited in the Config
--              Tool's Plant Hierarchy as one toggle per press under the
--              terminal's parent (LocationAttributeValueRow). Read through
--              Location.Terminal_ListDefaultMachines, which ignores any id
--              that is not an active equipment cell under the parent, so a
--              stale id never puts a foreign press on screen. An absent or
--              empty value shows every press, exactly as before.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0115_terminal_default_machines')
BEGIN PRINT 'Migration 0115 already applied -- skipping.'; RETURN; END
GO

IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'DefaultMachines' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'DefaultMachines', N'NVARCHAR', 0, NULL, NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'Machines this terminal shows as buttons by default (comma-separated Location ids). Empty = show every machine. Operators can still reach the rest through Show all.');
GO

-- Guarded like 0079: the top-of-file RETURN only exits its OWN batch.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0115_terminal_default_machines')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0115_terminal_default_machines',
            N'Location.LocationAttributeDefinition row: DefaultMachines (NVARCHAR, comma-separated Location ids) on LTD 7 (Terminal). Read by Location.Terminal_ListDefaultMachines.');
GO
PRINT 'Migration 0115 (terminal_default_machines) applied.';
GO
