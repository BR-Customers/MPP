-- ============================================================
-- Migration:   0133_shippinglabel_aimshipperid_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One small covering index so Global Trace finds a shipping label by its
--              AIM shipper id with a seek instead of scanning every label ever printed.
--
--   WHY (stored-procedure review, 2026-11-16). Lots.GlobalTrace_Resolve maps one
--   scanned/typed identifier to LOTs. Its branch 4 is
--       FROM Lots.ShippingLabel sl ... WHERE sl.AimShipperId = @Search
--   and it runs on EVERY search, whatever was typed (a LOT name, a serial, a container
--   id). Lots.ShippingLabel had no index with AimShipperId as a key
--   (IX_ShippingLabel_Container, IX_ShippingLabel_Stranded, IX_ShippingLabel_FailedUnacked),
--   so every Global Trace search scanned the whole label table, which grows by one row
--   per label printed (initial + reprints) and is never purged. Measured on a perf DB with
--   60,000 labels (about 14 months at one label every 10 minutes): 948 page reads and
--   about 11-13 ms CPU per search, every search; nothing else in the proc costs more than
--   a few pages.
--
--   The index is keyed on AimShipperId and INCLUDEs ContainerId, the only other column
--   branch 4 reads (Id is the clustered key and rides along). Not unique: a reprint or a
--   void + reprint writes another row with the same shipper id. No change to the proc or
--   its result set. Write cost: one more index row per label insert (labels are inserted
--   once per container plus reprints, a few hundred a day at most); AimShipperId is never
--   updated. Offline build on Standard edition; under a second at any realistic size.
--   ASCII only.
--
--   NUMBERING. 0119 is the container-as-LOT branch; 0120-0132 are used or claimed by
--   other review PRs. No dependency on any of them (needs Lots.ShippingLabel from 0028).
--   Renumber if the PRs merge in a different order.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND name = N'IX_ShippingLabel_AimShipperId')
    CREATE INDEX IX_ShippingLabel_AimShipperId
        ON Lots.ShippingLabel (AimShipperId)
        INCLUDE (ContainerId);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0133_shippinglabel_aimshipperid_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0133_shippinglabel_aimshipperid_index',
            N'Lots.ShippingLabel += IX_ShippingLabel_AimShipperId (AimShipperId) INCLUDE (ContainerId) for the Global Trace shipper-id lookup in Lots.GlobalTrace_Resolve (stored-procedure review 2026-11-16). No proc change.');
GO
