-- ============================================================
-- Migration:   0094_retire_low_inventory_horizon.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Description: Drops Parts.Item.LowInventoryHorizon (added by 0091, never shipped
--              to prod). Line Inventory spec revision 2 (Jacques, 2026-09-17)
--              colours a part by % of the line's consumption-point MaxQuantity
--              (Parts.ItemLocation) instead of a finished-good horizon x BOM
--              rollup, which broke at real scale (the RPY / 5BA sets roll up to
--              40-42 parts and machined WIP sat low all day).
--
--              0091 is already recorded in MPP_MES_Dev's SchemaVersion, so the
--              column is removed going forward rather than by editing 0091.
--              0092 is deliberately skipped: 0093 exists and may reach prod first.
--              BoxQuantity (also 0091) is kept.
-- ============================================================

IF OBJECT_ID(N'Parts.CK_Item_LowInventoryHorizon_Positive', N'C') IS NOT NULL
    ALTER TABLE Parts.Item DROP CONSTRAINT CK_Item_LowInventoryHorizon_Positive;
GO

IF COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NOT NULL
    ALTER TABLE Parts.Item DROP COLUMN LowInventoryHorizon;
GO

DECLARE @Gone NVARCHAR(20) = CASE WHEN COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NULL
                                  THEN N'dropped' ELSE N'STILL PRESENT' END;
PRINT 'Parts.Item.LowInventoryHorizon: ' + @Gone;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0094_retire_low_inventory_horizon')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0094_retire_low_inventory_horizon',
            N'Drop Parts.Item.LowInventoryHorizon (0091, never in prod). Line Inventory rev 2 colours by the line''s ItemLocation.MaxQuantity instead.');
GO
PRINT 'Migration 0094 (retire_low_inventory_horizon) applied.';
GO
