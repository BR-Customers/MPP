-- =============================================
-- Migration:   0065_crt_banner_label.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-20
-- Description: Part-scoped CRT (design 2026-08-19, decision D8 REVISED):
--              replace the inline {CrtMark} token with a SEPARATE CRT BANNER
--              LABEL printed alongside the normal LOT ticket.
--
--              A CRT LOT's ticket now prints EXACTLY as a clean LOT's does, and
--              a second, standalone label carrying nothing but a large 'CRT' is
--              emitted after it. A ZPL stream may hold several ^XA..^XZ
--              documents back to back and the printer emits one label per
--              document, so Lots.LotLabel_Print / _Reprint simply APPEND this
--              template's ZplBody to the rendered label when Lot.CrtActive = 1.
--              One proc call, two physical labels, no UI change.
--
--              Why this supersedes the {CrtMark} token (migration 0063): a whole
--              extra ticket is far more visible on the floor than a small mark
--              on one line, and -- decisively -- the banner requires NO edit to
--              MPP's real label layouts. 0063 had to splice a field into each
--              LTT template, could not patch a layout it did not recognise
--              (it PRINTed a WARNING when it skipped one), and had to be kept
--              clear of the ^BC / ^B3 barcode fields that carry the scanned LOT
--              number. None of that applies to a separate document. 0063's
--              WARNING block is therefore obsolete and is NOT carried forward.
--
--              This migration:
--                1. Adds the 'CrtBanner' Lots.LabelTypeCode row. Id is
--                   IDENTITY-assigned (0004's four rows used SET IDENTITY_INSERT
--                   for 1-4; nothing here depends on the number) and every
--                   consumer resolves it BY CODE.
--                2. Inserts its Lots.LabelTemplate row -- the banner is DATA,
--                   not ZPL hardcoded in a proc, so it is editable through the
--                   same template path as every other label.
--                3. Removes the {CrtMark} token from the active LTT templates.
--                   The procs no longer substitute it, so a surviving token
--                   would print LITERALLY on a production ticket.
--
--              Banner ZPL: ^XA^LH0,0^A0N,250,180^FO0,120^FB800,1,0,C^FDCRT^FS^XZ
--                * 800-dot field-block width with C(entre) justification. 800 is
--                  the usable width these labels already assume: the legacy
--                  'Container Hold' layout (zebraPrinter/Label Template -
--                  Container Hold.zpl) draws a ^GB750 rule from x=50 and wraps
--                  text in ^FB700 from x=50, i.e. a ~4in / 812-dot stock at
--                  203dpi. Centring in a block rather than at a fixed ^FO keeps
--                  the word centred if that width is ever retuned.
--                * ^A0N,250,180 -- character cell 180 wide x 250 tall. Three
--                  characters = 540 dots, comfortably inside the 800-dot block
--                  so it can never wrap. The legacy 'ON HOLD' banner on that
--                  same stock uses ^A0,200; this is deliberately larger still,
--                  because the whole point is that it is unmissable.
--                * ^LH0,0 restores the DEFAULT label home. ^LH persists on the
--                  printer until changed, and the banner is the LAST document in
--                  the stream -- leaving MPP's Primary ^LH50,50 in force would
--                  shift the FIRST document of whatever prints next. Resetting
--                  to the default is the only value that cannot surprise a
--                  later label.
--                * Nothing else on it: no LOT number, no part number, no
--                  barcode. It is a flag, not a record -- the record is the
--                  normal ticket printed immediately before it.
--
--              Idempotent-guarded on SchemaVersion (standard) AND per statement
--              (IF NOT EXISTS on both inserts, LIKE guards on the updates), so a
--              re-run is a no-op either way. No explicit transaction (repo
--              convention).
-- =============================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0065_crt_banner_label')
BEGIN PRINT 'Migration 0065 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. The CrtBanner label type (IDENTITY-assigned Id; resolved by Code) ----
IF NOT EXISTS (SELECT 1 FROM Lots.LabelTypeCode WHERE Code = N'CrtBanner')
    INSERT INTO Lots.LabelTypeCode (Code, Name)
    VALUES (N'CrtBanner', N'CRT Banner Label');
GO

-- ---- 2. The banner template ----
-- UQ_LabelTemplate_ActiveType is filtered UNIQUE on (LabelTypeCodeId) WHERE
-- DeprecatedAt IS NULL, so the guard below is also what keeps the insert legal.
DECLARE @CrtBannerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'CrtBanner');
DECLARE @BannerZpl NVARCHAR(MAX) = N'^XA^LH0,0^A0N,250,180^FO0,120^FB800,1,0,C^FDCRT^FS^XZ';

IF @CrtBannerTypeId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM Lots.LabelTemplate
                    WHERE LabelTypeCodeId = @CrtBannerTypeId AND DeprecatedAt IS NULL)
    INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody)
    VALUES (@CrtBannerTypeId, @BannerZpl);
GO

-- ---- 3. Strip {CrtMark} back out of the active LTT templates ----
-- Two known placements, handled surgically so no stray field or double space is
-- left behind, then a catch-all for anything hand-placed. Nothing substitutes
-- {CrtMark} any more, so a surviving token prints literally on a real ticket.

-- 3a. Migration 0063's inserted field, on 0021's placeholder layout.
UPDATE Lots.LabelTemplate
   SET ZplBody = REPLACE(ZplBody,
           N'^FO40,40^A0N,40,40^FDLOT {LotName}^FS^FO300,45^A0N,30,30^FD{CrtMark}^FS',
           N'^FO40,40^A0N,40,40^FDLOT {LotName}^FS')
 WHERE DeprecatedAt IS NULL
   AND ZplBody LIKE N'%^FO300,45^A0N,30,30^FD{CrtMark}^FS%';
GO

-- 3b. Seed 032's placement on MPP's real Primary layout (appended to the Lot
--     line). Restores that field to '^A0,64,48^FO100,100^FD{LotName}^FS'.
UPDATE Lots.LabelTemplate
   SET ZplBody = REPLACE(ZplBody, N'{LotName} {CrtMark}', N'{LotName}')
 WHERE DeprecatedAt IS NULL
   AND ZplBody LIKE N'%{LotName} {CrtMark}%';
GO

-- 3c. Catch-all for a token placed by hand somewhere neither 3a nor 3b knows.
--     Leaves an empty ^FD..^FS field at worst, which ZPL renders as nothing --
--     strictly better than printing the literal text '{CrtMark}'.
UPDATE Lots.LabelTemplate
   SET ZplBody = REPLACE(ZplBody, N'{CrtMark}', N'')
 WHERE DeprecatedAt IS NULL
   AND ZplBody LIKE N'%{CrtMark}%';
GO

-- ---- Verify ----
DECLARE @Remaining INT = (
    SELECT COUNT(*) FROM Lots.LabelTemplate
     WHERE DeprecatedAt IS NULL AND ZplBody LIKE N'%{CrtMark}%');
DECLARE @HasBanner INT = (
    SELECT COUNT(*) FROM Lots.LabelTemplate t
     INNER JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
     WHERE c.Code = N'CrtBanner' AND t.DeprecatedAt IS NULL);

IF @HasBanner <> 1
    PRINT 'WARNING: expected exactly 1 active CrtBanner label template, found '
        + CAST(@HasBanner AS NVARCHAR(10)) + ' -- a CRT LOT will print with NO banner.';
ELSE IF @Remaining > 0
    PRINT 'WARNING: ' + CAST(@Remaining AS NVARCHAR(10)) + ' active label template(s) still'
        + ' carry {CrtMark}; nothing substitutes it now, so it will print literally.';
ELSE
    PRINT 'CrtBanner template active; no active template carries a stale {CrtMark}.';
GO

-- ---- Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0065_crt_banner_label')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0065_crt_banner_label',
            N'CRT banner label: add the CrtBanner LabelTypeCode + LabelTemplate printed as a second ZPL document for a CRT LOT, and remove the {CrtMark} token from the active LTT templates (D8 revised).');
GO
PRINT 'Migration 0065 (CRT banner label) applied.';
GO
