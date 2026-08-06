-- ============================================================
-- Migration:   0047_lot_bom_asbuilt.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: As-built BOM capture on the LOT (LOT-detail "BOM version" display).
--                1. Lots.Lot += BomId BIGINT NULL (FK -> Parts.Bom) -- the exact BOM
--                   version consumed to build the LOT, stamped by the mint procs
--                   (Assembly_CompleteTray, MachiningOut_Mint) which already resolve it.
--                   NULL for raw/received/die-cast origins (no BOM).
--                2. One-time temporal BACKFILL for existing LOTs: the Bom version that
--                   was Published AND active (not yet Deprecated) at the LOT's CreatedAt
--                   -- a best-effort as-built reconstruction for historical rows. New
--                   LOTs get the authoritative stamped value from the mint procs going
--                   forward. LOTs whose item has no bracketing published BOM stay NULL.
--              Storing BomId (not just VersionNumber) preserves the exact version even
--              after later republishes. Idempotent, GO-separated.
-- ============================================================

-- ---- 1. Lots.Lot.BomId ----
IF COL_LENGTH(N'Lots.Lot', N'BomId') IS NULL
    ALTER TABLE Lots.Lot
        ADD BomId BIGINT NULL CONSTRAINT FK_Lot_Bom FOREIGN KEY (BomId) REFERENCES Parts.Bom(Id);
GO

-- ---- 2. Temporal backfill (batch break so the new column is visible) ----
UPDATE l
   SET BomId = x.BomId
FROM Lots.Lot l
CROSS APPLY (
    SELECT TOP 1 b.Id AS BomId
    FROM Parts.Bom b
    WHERE b.ParentItemId = l.ItemId
      AND b.PublishedAt IS NOT NULL
      AND b.PublishedAt <= l.CreatedAt
      AND (b.DeprecatedAt IS NULL OR b.DeprecatedAt > l.CreatedAt)
    ORDER BY b.VersionNumber DESC
) x
WHERE l.BomId IS NULL;
GO

-- ---- record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0047_lot_bom_asbuilt')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0047_lot_bom_asbuilt',
        N'As-built BOM capture: Lots.Lot += BomId (FK Parts.Bom), stamped by mint procs; one-time temporal backfill of existing LOTs.');
GO

PRINT 'Migration 0047 (LOT as-built BomId + temporal backfill) applied.';
GO
