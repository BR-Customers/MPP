-- ============================================================
-- Migration:   0095_retire_component_projection.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-18
-- Description: Drops Workorder.Assembly_GetComponentProjection -- the Assembly OUT
--              (non-serialized) sidebar's "tray projection" (on hand vs. the trays
--              left in the current container).
--
--              REPLACED BY the M&A Line Inventory panel (spec
--              docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md,
--              revision 2), which colours a part by % of the line's
--              Parts.ItemLocation.MaxQuantity via Lots.Lot_GetLineInventorySummary.
--              The low-inventory toast that also read this proc is retired
--              (Jacques, 2026-09-17), and the sidebar that bound it was removed
--              from Views/ShopFloor/AssemblyNonSerialized in the same change set.
--
--              Its repeatable file is deleted in the same commit so a later
--              Update-Prod does not recreate it. Number 0092 was abandoned: 0093
--              exists and may reach prod first, which would leave a later 0092
--              below the high-water mark.
-- ============================================================

IF OBJECT_ID(N'Workorder.Assembly_GetComponentProjection', N'P') IS NOT NULL
    DROP PROCEDURE Workorder.Assembly_GetComponentProjection;
GO

DECLARE @Gone NVARCHAR(20) = CASE WHEN OBJECT_ID(N'Workorder.Assembly_GetComponentProjection', N'P') IS NULL
                                  THEN N'dropped' ELSE N'STILL PRESENT' END;
PRINT 'Workorder.Assembly_GetComponentProjection: ' + @Gone;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0095_retire_component_projection')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0095_retire_component_projection',
            N'Drop Workorder.Assembly_GetComponentProjection (Assembly OUT tray projection), replaced by the M&A Line Inventory panel (ItemLocation.MaxQuantity colour scale).');
GO
PRINT 'Migration 0095 (retire_component_projection) applied.';
GO
