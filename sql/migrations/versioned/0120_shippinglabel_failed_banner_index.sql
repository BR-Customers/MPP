-- ============================================================
-- Migration:   0120_shippinglabel_failed_banner_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-13
-- Description: One filtered, covering index so the print-failure banner read
--              (Lots.ShippingLabel_GetForBanner) finds its few rows by seek instead of
--              scanning every shipping label ever printed.
--
--   WHY (stored-procedure review, 2026-11-13). PrintFailureGateway.broadcastTick runs
--   Lots.ShippingLabel_GetForBanner about every 5 seconds on the gateway. The proc is
--       SELECT Id, ContainerId, TerminalLocationId, AimShipperId, LastPrintError,
--              LastPrintErrorCondition
--       FROM Lots.ShippingLabel
--       WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL;
--   and Lots.ShippingLabel had only IX_ShippingLabel_Container (ContainerId) and
--   IX_ShippingLabel_Stranded (CreatedAt WHERE PrintedAt IS NULL AND PrintFailedAt IS
--   NULL, which is the OPPOSITE arm), so every tick scanned the whole table, which
--   grows with every label ever printed. The wanted rows are almost always zero or a
--   handful.
--
--   The index holds only failed, not-yet-acknowledged labels (the banner's working set)
--   and INCLUDEs every column the proc selects, so the read is an index-only seek. No
--   change to the proc or to its result set. Write cost: every label insert / print-
--   failure stamp / banner acknowledgement maintains one more (almost always empty)
--   index. Offline build on Standard edition; seconds at any realistic size. ASCII only.
--
--   NUMBERING. 0119 is claimed by the container-as-LOT branch (PROJECT_STATUS.md says to
--   renumber its 0118 to 0119 before it merges), so this is 0120. If that branch lands
--   differently, renumber this file; it has no dependency on any other new migration
--   (it needs Lots.ShippingLabel from 0028 and LastPrintErrorCondition from 0102).
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND name = N'IX_ShippingLabel_FailedUnacked')
    CREATE INDEX IX_ShippingLabel_FailedUnacked
        ON Lots.ShippingLabel (PrintFailedAt)
        INCLUDE (ContainerId, TerminalLocationId, AimShipperId, LastPrintError, LastPrintErrorCondition)
        WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0120_shippinglabel_failed_banner_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0120_shippinglabel_failed_banner_index',
            N'Lots.ShippingLabel += IX_ShippingLabel_FailedUnacked (filtered PrintFailedAt NOT NULL AND BannerAcknowledgedAt NULL, covering) for the 5 s print-failure banner read (stored-procedure review 2026-11-13). No proc change.');
GO
