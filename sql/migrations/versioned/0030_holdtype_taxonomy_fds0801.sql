-- ============================================================
-- Migration:   0030_holdtype_taxonomy_fds0801.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-25
-- Description: Correct the Quality.HoldTypeCode taxonomy to FDS-08-001, which
--              specifies the hold types QUALITY, CUSTOMER_COMPLAINT, PRECAUTIONARY.
--              The original 0004 seed shipped QualityHold / EngineeringHold /
--              CustomerHold -- "Engineering" is not an FDS type and "Precautionary"
--              was missing. Ids are preserved (HoldEvent.HoldTypeCodeId FKs are
--              unaffected); only Code/Name are corrected. (FDS congruity review A1,
--              2026-06-25.)
-- ============================================================

UPDATE Quality.HoldTypeCode SET Code = N'Quality',           Name = N'Quality'            WHERE Id = 1;
UPDATE Quality.HoldTypeCode SET Code = N'CustomerComplaint', Name = N'Customer Complaint'  WHERE Id = 2;
UPDATE Quality.HoldTypeCode SET Code = N'Precautionary',     Name = N'Precautionary'      WHERE Id = 3;
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0030_holdtype_taxonomy_fds0801')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0030_holdtype_taxonomy_fds0801',
        N'FDS-08-001 hold-type taxonomy: QualityHold/EngineeringHold/CustomerHold -> Quality/CustomerComplaint/Precautionary (Ids preserved).');
GO

PRINT 'Migration 0030 (HoldTypeCode taxonomy -> FDS-08-001) applied.';
GO
