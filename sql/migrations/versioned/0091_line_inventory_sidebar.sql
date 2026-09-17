-- ============================================================
-- Migration:   0091_line_inventory_sidebar.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Description: Two Parts.Item settings for the M&A Line Inventory sidebar
--              (spec 2026-09-17-line-inventory-sidebar-design.md).
--
--              BoxQuantity INT NULL -- pieces in one purchased box (dowel pins
--              come in 5000s). A PassThrough part with a BoxQuantity gets a
--              one-tap check-in button that creates one Received LOT of this
--              size; without one, the button asks for a count.
--
--              LowInventoryHorizon INT NULL -- set on a FinishedGood: "warn me
--              when the line can't build this many more". A component of a
--              running FG is low when on hand < rolled-up QtyPer x horizon.
--
--              Both are nullable and metadata-only on Parts.Item (no backfill).
--              The > 0 rule is a CHECK; which ItemType may carry each value is
--              enforced in Parts.Item_Update (a CHECK would hard-code type Ids).
-- ============================================================

IF COL_LENGTH('Parts.Item', 'BoxQuantity') IS NULL
    ALTER TABLE Parts.Item
        ADD BoxQuantity INT NULL
            CONSTRAINT CK_Item_BoxQuantity_Positive CHECK (BoxQuantity IS NULL OR BoxQuantity > 0);
GO

IF COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NULL
    ALTER TABLE Parts.Item
        ADD LowInventoryHorizon INT NULL
            CONSTRAINT CK_Item_LowInventoryHorizon_Positive CHECK (LowInventoryHorizon IS NULL OR LowInventoryHorizon > 0);
GO

DECLARE @Box NVARCHAR(20) = CASE WHEN COL_LENGTH('Parts.Item', 'BoxQuantity') IS NOT NULL THEN N'present' ELSE N'MISSING' END;
DECLARE @Hz  NVARCHAR(20) = CASE WHEN COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NOT NULL THEN N'present' ELSE N'MISSING' END;
PRINT 'Parts.Item.BoxQuantity: ' + @Box;
PRINT 'Parts.Item.LowInventoryHorizon: ' + @Hz;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0091_line_inventory_sidebar')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0091_line_inventory_sidebar',
            N'Parts.Item.BoxQuantity (INT NULL, > 0; PassThrough one-tap check-in size) and Parts.Item.LowInventoryHorizon (INT NULL, > 0; FinishedGood low-stock horizon) for the M&A Line Inventory sidebar.');
GO
PRINT 'Migration 0091 (line_inventory_sidebar) applied.';
GO
