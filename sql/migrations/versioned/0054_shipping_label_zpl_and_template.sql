-- ============================================================
-- Migration: 0054_shipping_label_zpl_and_template.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-07
-- Description: Brief D (FAT-LBL-050 / FAT-LBL-060) -- bring the container shipping
--   label onto the Lots.LabelTemplate pattern the LTT label already uses.
--
--     1. ADD Lots.ShippingLabel.ZplContent NVARCHAR(MAX) NULL -- persist the rendered
--        ZPL payload on the shipping-label record (LBL-060).
--     2. Replace the active Container Lots.LabelTemplate with an ASCII port of the
--        real legacy Honda container label (zebraPrinter/Label Template - Container.zpl).
--        Migration 0021 seeds a GENERIC placeholder template for all four LabelTypeCodes
--        (LTT-style {LotName} tokens); this migration DEPRECATES that placeholder for the
--        'Container' type (Id 2 -- the code Container_Complete stamps) and inserts the
--        ported Honda label whose Flexware <<TOKEN:{0}>> merge fields are rewritten as
--        {Placeholder} tokens resolved at render time by Lots.ufn_ShippingLabelZpl
--        (LBL-050). Deprecate-then-insert honors the append-only soft-delete design and
--        the filtered-unique index UQ_LabelTemplate_ActiveType (one active per type).
--        Primary/Master/Void keep their 0021 placeholder (out of scope).
--
--   Blank-by-design tokens ({PartNumberExt}, {DataMatrix}, {Auditor}) are perpetuated
--   blank -- MPP confirms these fields are empty on every real container label; the
--   layout + captions are retained. ASCII-only (verified by byte scan).
--
--   Batch-guard note (mirror 0053): RETURN aborts only the FIRST batch, so each
--   GO-separated batch carries its own IF NOT EXISTS(SchemaVersion) guard.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0054_shipping_label_zpl_and_template')
BEGIN PRINT 'Migration 0054 already applied -- skipping.'; RETURN; END
GO

-- 1. ShippingLabel.ZplContent (guarded twice: SchemaVersion re-apply + COL_LENGTH).
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0054_shipping_label_zpl_and_template')
   AND COL_LENGTH(N'Lots.ShippingLabel', N'ZplContent') IS NULL
BEGIN
    ALTER TABLE Lots.ShippingLabel ADD ZplContent NVARCHAR(MAX) NULL;
END
GO

-- 2. Seed the active Container LabelTemplate (ported Honda ZPL) if none exists.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0054_shipping_label_zpl_and_template')
BEGIN
    DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');

    IF @ContainerTypeId IS NOT NULL
    BEGIN
        DECLARE @Zpl NVARCHAR(MAX) =
N'^XA
^A0R,24,26^FO740,20^FDPART NO. (P)^FS
^A0R,86,86^FO690,200^FD{PartNumber}^FS
^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS
^FO660,1100^BXR,5,200,,,,^FD{DataMatrix}^FS
^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS
^A0R,72,72^FO480,70^FD{PartNumberExt}^FS
^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS
^A0R,24,24^FO550,670^FDDESCRIPTION^FS
^A0R,45,36^FO500,670^FD{Description}^FS
^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS
^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS
^A0R,24,24^FO460,1070^FDMFG DATE^FS
^A0R,45,36^FO410,1070^FD{MfgDate}^FS
^A0R,24,24^FO460,940^FDAUDIT^FS
^A0R,45,36^FO420,940^FD{Auditor}^FS
^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS
^A0R,72,72^FO300,70^FD{DcPartLevel}^FS
^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS
^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS
^A0R,72,72^FO240,720^FD{Quantity}^FS
^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS
^A0R,24,24^FO190,20^FDSERIAL (1S)^FS
^A0R,72,72^FO140,200^FD{Serial}^FS
^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS
^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS
^A0R,24,24^FO20,220^FD{Coo}^FS
^FO580,10^GB0,1300,3^FS
^FO490,650^GB0,905,3^FS
^FO400,10^GB0,1300,3^FS
^FO220,10^GB0,1300,3^FS
^FO220,650^GB360,0,3^FS
^PQ2
^XZ';
        -- Deprecate the generic 0021 placeholder (or any prior) active Container template,
        -- then install the ported Honda label as the new active template.
        UPDATE Lots.LabelTemplate
        SET    DeprecatedAt = SYSUTCDATETIME()
        WHERE  LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL;

        INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody) VALUES (@ContainerTypeId, @Zpl);
    END
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0054_shipping_label_zpl_and_template')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0054_shipping_label_zpl_and_template',
            N'Add Lots.ShippingLabel.ZplContent + seed active Container LabelTemplate (ported Honda ZPL, {Placeholder} tokens).');
GO
PRINT 'Migration 0054 (shipping label ZplContent + Container template) applied.';
GO
