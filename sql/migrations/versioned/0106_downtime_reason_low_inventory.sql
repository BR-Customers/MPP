-- ============================================================
-- Migration:   0106_downtime_reason_low_inventory.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Description: Oee.DowntimeReasonCode += MA-LOWINV 'Low Inventory'.
--
--   WHY. The Assembly OUT low-inventory lock opens a System-source downtime
--   event when a purchased part is 3 trays from running out, and ends it when
--   stock is added. That event needs a reason the software can name by Code;
--   the MPP-supplied reasons (MS-0448 'No Parts to Assemble', MS-0511
--   'Inventory') are plant-owned text that may be renamed or deprecated.
--
--   This is an internal code baked into a migration, not a Seeding Registry
--   item. Machining & Assembly category, System source, not excused, no
--   reason type. ASCII only.
--
--   Spec: docs/superpowers/specs/2026-10-06-assembly-out-low-inventory-lock-design.md
-- ============================================================
IF EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = N'MA-LOWINV')
BEGIN
    PRINT 'Migration 0106: DowntimeReasonCode MA-LOWINV already present -- no change.';
END
ELSE
BEGIN
    INSERT INTO Oee.DowntimeReasonCode
        (Code, Description, OperationCategoryId, DowntimeReasonTypeId, DowntimeSourceCodeId, IsExcused, CreatedByUserId)
    SELECT N'MA-LOWINV', N'Low Inventory', oc.Id, NULL, src.Id, 0, 1
    FROM Parts.OperationCategory oc
    CROSS JOIN Oee.DowntimeSourceCode src
    WHERE oc.Code = N'MachiningAssembly' AND src.Code = N'System';
    PRINT 'Migration 0106: DowntimeReasonCode MA-LOWINV added.';
END
GO

IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = N'MA-LOWINV' AND DeprecatedAt IS NULL)
    THROW 51000, 'Migration 0106: DowntimeReasonCode MA-LOWINV did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0106_downtime_reason_low_inventory')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0106_downtime_reason_low_inventory',
            N'Oee.DowntimeReasonCode += MA-LOWINV Low Inventory (System source): the reason the Assembly OUT low-inventory lock stamps on its downtime event.');
GO
PRINT 'Migration 0106 (downtime_reason_low_inventory) applied.';
GO
