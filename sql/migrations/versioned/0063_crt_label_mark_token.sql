-- =============================================
-- Migration:   0063_crt_label_mark_token.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-20
-- Description: Part-scoped CRT (design 2026-08-19 section 4, decision D8),
--              Task 6 of the feature: the {CrtMark} label token.
--
--              Adds the {CrtMark} placeholder to the active ZplBody of the
--              three LOT Tracking Ticket label types seeded by migration 0021
--              (Primary=1, Master=3, Void=4) -- ALL of which share the same
--              generic {LotName}-style template. One token in the EXISTING
--              templates rather than separate CRT template variants (D8): no
--              duplication, nothing to drift. Positioned right of the LOT
--              number field so the mark reads as part of that line.
--
--              Migration 0021 is already applied and immutable (repo
--              convention: never modify an applied versioned migration), so
--              the token is added here as a data UPDATE against the live
--              Lots.LabelTemplate rows rather than by editing 0021's seed.
--
--              The Container (Id 2) label type is OUT OF SCOPE: migration
--              0054 replaced its active template with the ported Honda
--              shipping-label ZPL, which uses an entirely different token set
--              ({PartNumber}/{Serial}/etc.) and is rendered by
--              Lots.ufn_ShippingLabelZpl, not the LotLabel_Print/_Reprint
--              {LotName}-token chain this task touches. The WHERE clause below
--              is belt-and-suspenders: it only ever matches rows that still
--              carry the 0021-style {LotName} body, so Container's Honda ZPL
--              (which has no {LotName} token) is never touched even if a
--              future re-run widened the LabelTypeCodeId filter.
--
--              Idempotent-guarded on SchemaVersion (standard) AND on the
--              UPDATE itself (ZplBody NOT LIKE '%{CrtMark}%'), so a re-run
--              is a no-op either way. No explicit transaction (repo
--              convention).
-- =============================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0063_crt_label_mark_token')
BEGIN PRINT 'Migration 0063 already applied -- skipping.'; RETURN; END
GO

-- Insert a {CrtMark} field immediately after the LOT-number field, on the
-- active template for the three LTT label types (Primary/Master/Void). The
-- ZplBody LIKE guard scopes the replace to rows that actually carry the
-- 0021-style {LotName} anchor (Container's ported Honda ZPL does not, so it
-- is never touched); the NOT LIKE guard makes the UPDATE itself idempotent.
UPDATE Lots.LabelTemplate
   SET ZplBody = REPLACE(ZplBody,
           N'^FO40,40^A0N,40,40^FDLOT {LotName}^FS',
           N'^FO40,40^A0N,40,40^FDLOT {LotName}^FS^FO300,45^A0N,30,30^FD{CrtMark}^FS')
 WHERE LabelTypeCodeId IN (1, 3, 4)
   AND DeprecatedAt IS NULL
   AND ZplBody LIKE N'%^FO40,40^A0N,40,40^FDLOT {LotName}^FS%'
   AND ZplBody NOT LIKE N'%{CrtMark}%';
GO

-- ---- Warn about any ACTIVE LTT template this migration could not patch ----
-- The REPLACE above anchors on migration 0021's seeded field string. A site whose
-- Primary/Master/Void template was replaced with a real plant layout (MPP_MES_Dev
-- already carries one, loaded out-of-band) will NOT match that anchor and is
-- silently skipped -- which would ship a CRT LOT whose ticket carries no mark.
-- A blanket REPLACE on the bare {LotName} token is NOT a safe fix: every active
-- LTT template carries TWO occurrences, and the Master and Void templates put one
-- of them inside a ^BC barcode field, so injecting the mark there would corrupt
-- the scanned LOT number. Adding the mark to a real layout is a per-template
-- placement decision. Fail loudly here rather than leaving it to be discovered on
-- a printed ticket.
DECLARE @Unpatched INT = (
    SELECT COUNT(*) FROM Lots.LabelTemplate
     WHERE LabelTypeCodeId IN (1, 3, 4)
       AND DeprecatedAt IS NULL
       AND ZplBody NOT LIKE N'%{CrtMark}%');
IF @Unpatched > 0
    PRINT 'WARNING: ' + CAST(@Unpatched AS NVARCHAR(10)) + ' active LTT label template(s)'
        + ' do not carry {CrtMark} and were skipped -- a CRT LOT will print with NO mark'
        + ' on those tickets. Add a {CrtMark} field to each by hand, outside any ^BC'
        + ' barcode field. See docs/superpowers/specs/2026-08-19-crt-part-scoped-design.md D8.';
ELSE
    PRINT 'All active LTT label templates carry {CrtMark}.';
GO

-- ---- Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0063_crt_label_mark_token')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0063_crt_label_mark_token',
            N'Add {CrtMark} placeholder to the active Primary/Master/Void LabelTemplate ZplBody rows (D8).');
GO
PRINT 'Migration 0063 (CRT label mark token) applied.';
GO
