-- ============================================================
-- Migration:   0047_container_label_template.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-28
-- Description: Dual-transport label printing (design 2026-07-28) part 2.
--              Replaces the ACTIVE 'Container' LabelTemplate body. The 0021 seed
--              gave ALL FOUR label types the same LOT-shaped placeholder ZPL, so a
--              Container-type render produced a lot label; and the real container
--              layout lived as a hard-coded Python constant in
--              BlueRidge.Lots.ShippingDispatcher, which FDS sec 2064 forbids
--              ("ZPL templates SHALL be configurable, not hard-coded").
--
--              Layout flattened from zebraPrinter/Label Template - Container.zpl;
--              positions/fonts/lines preserved. Tokens resolve from
--              Lots.Container_GetLabelData. The Honda-specific fields (PartExt,
--              PartLevel, Auditor) render blank until sourced, and their un-sourced
--              barcodes (2D DataMatrix, part-ext, part-level) are omitted. ^PQ2 = 2
--              copies, per the source label.
--
--              WARNING: this makes LabelTypeCodeId 2 unusable through Lots.LotLabel_Print
--              (its token vocabulary no longer overlaps LOT-shaped tokens) -- see that
--              proc's header for the full explanation.
--              Idempotent (re-apply = no-op). ASCII-only.
-- ============================================================

UPDATE Lots.LabelTemplate
SET ZplBody =
    N'^XA^POI' +
    N'^A0R,24,26^FO740,20^FDPART NO. (P)^FS' +
    N'^A0R,86,86^FO690,200^FD{PartNumber}^FS' +
    N'^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS' +
    N'^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS' +
    N'^A0R,72,72^FO480,70^FD{PartExt}^FS' +
    N'^A0R,24,24^FO550,670^FDDESCRIPTION^FS' +
    N'^A0R,45,36^FO500,670^FD{Description}^FS' +
    N'^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS' +
    N'^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS' +
    N'^A0R,24,24^FO460,1070^FDMFG DATE^FS' +
    N'^A0R,45,36^FO410,1070^FD{MfgDate}^FS' +
    N'^A0R,24,24^FO460,940^FDAUDIT^FS' +
    N'^A0R,45,36^FO420,940^FD{Auditor}^FS' +
    N'^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS' +
    N'^A0R,72,72^FO300,70^FD{PartLevel}^FS' +
    N'^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS' +
    N'^A0R,72,72^FO240,720^FD{Quantity}^FS' +
    N'^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS' +
    N'^A0R,24,24^FO190,20^FDSERIAL (1S)^FS' +
    N'^A0R,72,72^FO140,200^FD{Serial}^FS' +
    N'^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS' +
    N'^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS' +
    N'^A0R,24,24^FO20,220^FD{CountryOfOrigin}^FS' +
    N'^FO580,10^GB0,1300,3^FS' +
    N'^FO490,650^GB0,905,3^FS' +
    N'^FO400,10^GB0,1300,3^FS' +
    N'^FO220,10^GB0,1300,3^FS' +
    N'^FO220,650^GB360,0,3^FS' +
    N'^PQ2' +
    N'^XZ'
WHERE LabelTypeCodeId = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container')
  AND DeprecatedAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0047_container_label_template')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0047_container_label_template',
            N'Honda container shipping-label ZPL moved from a Python constant into the active Container LabelTemplate.');
GO

PRINT 'Migration 0046 (container label template) applied.';
GO
