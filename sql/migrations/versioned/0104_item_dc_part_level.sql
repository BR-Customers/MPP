-- ============================================================
-- Migration:   0104_item_dc_part_level.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-05
-- Description: Parts.Item.DcPartLevel TINYINT NULL -- the D/C PART LEVEL (2P)
--              printed on the Container shipping label, as an ENTERED value on
--              the part instead of a derived one.
--
--   WHY. The label's D/C PART LEVEL was derived from the BOM version actually
--   recorded on the tray's finished-good LOT (ufn_ShippingLabelZpl v1.1,
--   migration 0074 lineage). That is internally consistent -- it reports the BOM
--   the container was really built against -- but it is not what the field
--   MEANS to Honda. Found onsite 2026-10-05: part 1223A-6MA -J000 printed '04'
--   because the repo carries four BOM revisions for it, while its true D/C part
--   level is '00'. The two numbers are unrelated and happened to share a format.
--
--   NULLABLE, and NULL means '00'. Decided with Jacques onsite. Every row is NULL
--   the moment this lands, so every label prints '00' from the next container
--   until the field is populated -- which is correct for this part and for most,
--   and is the point: a wrong-but-plausible derived number is replaced by a
--   consistent default that somebody can correct per part.
--
--   >> CONSEQUENCE, STATED PLAINLY: any part whose true level is NOT 00 will
--   >> print 00 until its row is set. The BOM-derived value is gone, not kept as
--   >> a fallback, because keeping it would mean two different numbers appearing
--   >> in one field depending on whether anyone had touched that part yet.
--
--   TINYINT (0-255), not NVARCHAR. Jacques's call: the field is numeric and
--   zero-padded to two digits at render time, so the type enforces what the
--   label needs and no row can hold '4 ' or 'O0'. A level above 255 is not
--   representable -- it would render correctly as three digits if the type were
--   widened, and widening is a one-line ALTER if MPP ever needs it.
--
--   0 IS A VALID VALUE, which rules out the sentinel Parts.Item_Update uses for
--   BoxQuantity (0 = clear). Clearing back to NULL is handled there with an
--   explicit -1 on a SMALLINT parameter instead; see that proc's header.
-- ============================================================
IF COL_LENGTH('Parts.Item', 'DcPartLevel') IS NOT NULL
BEGIN
    PRINT 'Migration 0104: Parts.Item.DcPartLevel already present -- no change.';
END
ELSE
BEGIN
    ALTER TABLE Parts.Item ADD DcPartLevel TINYINT NULL;
    PRINT 'Migration 0104: Parts.Item.DcPartLevel added.';
END
GO

IF COL_LENGTH('Parts.Item', 'DcPartLevel') IS NULL
    THROW 51000, 'Migration 0104: DcPartLevel did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0104_item_dc_part_level')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0104_item_dc_part_level',
            N'Parts.Item.DcPartLevel TINYINT NULL: the D/C PART LEVEL (2P) printed on the Container shipping label, entered per part instead of derived from the BOM version. NULL renders as 00. Apply with Lots.ufn_ShippingLabelZpl v1.4, Parts.Item_Get v2.5 and Parts.Item_Update v2.8.');
GO
PRINT 'Migration 0104 (item_dc_part_level) applied.';
GO
