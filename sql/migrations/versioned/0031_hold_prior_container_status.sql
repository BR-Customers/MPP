-- ============================================================
-- Migration:   0031_hold_prior_container_status.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-29
-- Description: P7-7 fix. Quality.Hold_Release restored a held Container to
--              Complete (2) UNCONDITIONALLY, so a SHIPPED container placed on
--              hold (e.g. a Honda recall) and later released came back as
--              Complete and was re-shippable via Container_Ship -> a silent
--              double-ship with no trace. Mirror the LOT path (which restores
--              the prior status from LotStatusHistory) by capturing the
--              container's pre-hold status on the HoldEvent at place time and
--              restoring it on release. Adds
--              Quality.HoldEvent.PriorContainerStatusCodeId -- NULL for LOT
--              holds and for any pre-0031 rows, in which case Hold_Release
--              falls back to Complete (2) as before. (ARC2_REVIEW_FINDINGS P7-7.)
-- ============================================================

IF COL_LENGTH('Quality.HoldEvent', 'PriorContainerStatusCodeId') IS NULL
    ALTER TABLE Quality.HoldEvent
        ADD PriorContainerStatusCodeId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_HoldEvent_PriorContainerStatus')
    ALTER TABLE Quality.HoldEvent
        ADD CONSTRAINT FK_HoldEvent_PriorContainerStatus
        FOREIGN KEY (PriorContainerStatusCodeId) REFERENCES Lots.ContainerStatusCode(Id);
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0031_hold_prior_container_status')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0031_hold_prior_container_status',
        N'P7-7: add Quality.HoldEvent.PriorContainerStatusCodeId so Hold_Release restores a container to its pre-hold status (prevents shipped->hold->release double-ship).');
GO

PRINT 'Migration 0031 (HoldEvent.PriorContainerStatusCodeId) applied.';
GO
