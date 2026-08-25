-- =============================================
-- Migration:   0064_rfid_label_placeholder.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-20
-- Description: Backlog item - "Add RFID column to label data for future phase."
--              A nullable RfidTag column reserved on both label print/history
--              tables (LTT and shipping) so a future RFID-encoding phase has
--              somewhere to persist the EPC/tag value written onto an
--              RFID-capable label. NOT populated or read anywhere yet -- no
--              ZPL template, render proc, or UI references it. Scope per
--              CLAUDE.md's FUTURE convention: schema-only placeholder, no
--              behavior. Nullable, not NOT NULL: retrofit onto existing rows,
--              and the vast majority of labels printed today are non-RFID
--              stock.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF COL_LENGTH(N'Lots.LotLabel', N'RfidTag') IS NULL
    ALTER TABLE Lots.LotLabel ADD RfidTag NVARCHAR(100) NULL;
GO

IF COL_LENGTH(N'Lots.ShippingLabel', N'RfidTag') IS NULL
    ALTER TABLE Lots.ShippingLabel ADD RfidTag NVARCHAR(100) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0064_rfid_label_placeholder')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0064_rfid_label_placeholder',
        N'Add RfidTag (NVARCHAR(100) NULL) to Lots.LotLabel and Lots.ShippingLabel - unpopulated placeholder for a future RFID-encoding phase.');
GO

PRINT 'Migration 0064 (rfid_label_placeholder) applied.';
GO
