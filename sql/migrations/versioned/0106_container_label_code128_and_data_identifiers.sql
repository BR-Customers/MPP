-- ============================================================
-- Migration:   0106_container_label_code128_and_data_identifiers.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Description: The four linear barcodes on the Container shipping label are
--              brought in line with the label Honda's AIM batch-print tool
--              produces for the same part: Code 128 instead of Code 39, and each
--              payload led by its data identifier.
--
--   WHY. Onsite 2026-10-06, our label and an AIM batch label for 1223A-6MA -J000
--   were scanned side by side:
--
--       field            AIM batch label        ours (before this migration)
--       PART NO. (P)     P1223A6MA J000         1223A-6MA -J000
--       D/C LEVEL (2P)   2P00                   00
--       QUANTITY (Q)     Q96                    Q96
--       SERIAL (1S)      1S1321800113936248     1321800113906382
--
--   Three of four payloads differed, and ours printed roughly 1.6x as long.
--
--   1. DATA IDENTIFIERS. Each barcode carries the identifier printed in its own
--      caption (P / 2P / Q / 1S). Only Q was there before. The prefixes are
--      LITERALS IN THE TEMPLATE, the way 'Q{Quantity}' always has been, so the
--      tokens keep meaning "the value".
--
--   2. PART NUMBER, BARCODE FORM. {PartNumberBarcode} is the part number with
--      every '-' removed (the space is kept): '1223A-6MA -J000' ->
--      '1223A6MA J000'. Same rule the {DataMatrix} payload has used since
--      ufn_ShippingLabelZpl v1.3. The human-readable line keeps {PartNumber}.
--
--   3. CODE 128, AUTOMATIC SUBSET (^BC mode A). The scanner app used onsite did
--      not name the symbology. Code 128 is INFERRED from tape-measure lengths of
--      the AIM label, which fit Code 128 at one module width across the part
--      number, D/C level and serial barcodes (the serial only fits with digit
--      pairs packed, hence mode A) and fit Code 39 on none of them. If a scanner
--      that reports the format ever says otherwise, this is the line to revisit.
--
--   >> LENGTH WILL BE CLOSE, NOT IDENTICAL. The AIM label measures out to a
--   >> 13.3 mil module (4 dots on a 300 dpi head). Our printer is 203 dpi, where
--   >> the choices are ^BY3 = 14.8 mil or ^BY2 = 9.9 mil; ^BY3 is kept, so ours
--   >> prints about 11% longer than AIM's (and about 2/3 the length it was).
--   >> The decoded content is what is made identical here.
--
--   NOT TOUCHED: the human-readable text, the 2D DataMatrix, positions, heights.
--
--   IDEMPOTENT + GUARDED, same shape as 0103: every edit asserts it matched the
--   line it meant to. NO EXPLICIT TRANSACTION -- Deploy-ProdRelease.ps1 owns it.
--
--   Apply with Lots.ufn_ShippingLabelZpl v1.5, which supplies
--   {PartNumberBarcode}. An older function would print that token literally.
-- ============================================================
SET NOCOUNT ON;

DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
IF @ContainerTypeId IS NULL
    THROW 51000, 'Migration 0106: no Container LabelTypeCode -- schema is not where this migration expects.', 1;

DECLARE @Id BIGINT = (SELECT TOP 1 Id FROM Lots.LabelTemplate
                      WHERE LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL
                      ORDER BY Id);
IF @Id IS NULL
    THROW 51000, 'Migration 0106: no active Container LabelTemplate to patch.', 1;

DECLARE @Body NVARCHAR(MAX) = (SELECT ZplBody FROM Lots.LabelTemplate WHERE Id = @Id);

DECLARE @OldPart   NVARCHAR(200) = N'^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS';
DECLARE @NewPart   NVARCHAR(200) = N'^FO600,70^BY3^BCR,100,N,N,N,A^FDP{PartNumberBarcode}^FS';

DECLARE @OldLevel  NVARCHAR(200) = N'^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS';
DECLARE @NewLevel  NVARCHAR(200) = N'^FO230,70^BY3^BCR,75,N,N,N,A^FD2P{DcPartLevel}^FS';

DECLARE @OldQty    NVARCHAR(200) = N'^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS';
DECLARE @NewQty    NVARCHAR(200) = N'^FO320,720^BY3^BCR,75,N,N,N,A^FDQ{Quantity}^FS';

DECLARE @OldSerial NVARCHAR(200) = N'^A0R^FO50,60^BY3^B3,,95,N,^FD{SerialBarcode}^FS';
DECLARE @NewSerial NVARCHAR(200) = N'^FO50,60^BY3^BCR,95,N,N,N,A^FD1S{SerialBarcode}^FS';

-- Already applied? (re-run safety)
IF CHARINDEX(@NewPart, @Body) > 0 AND CHARINDEX(@NewLevel, @Body) > 0
   AND CHARINDEX(@NewQty, @Body) > 0 AND CHARINDEX(@NewSerial, @Body) > 0
   AND CHARINDEX(N'^B3', @Body) = 0
BEGIN
    PRINT 'Migration 0106: Container label already patched -- no change.';
END
ELSE
BEGIN
    IF CHARINDEX(@OldPart, @Body) = 0
        THROW 51000, 'Migration 0106: the PART NO. (P) Code 39 field was not found verbatim. The template has diverged -- inspect Lots.LabelTemplate before re-running.', 1;
    IF CHARINDEX(@OldLevel, @Body) = 0
        THROW 51000, 'Migration 0106: the D/C PART LEVEL (2P) Code 39 field was not found verbatim. The template has diverged -- inspect Lots.LabelTemplate before re-running.', 1;
    IF CHARINDEX(@OldQty, @Body) = 0
        THROW 51000, 'Migration 0106: the QUANTITY (Q) Code 39 field was not found verbatim. The template has diverged -- inspect Lots.LabelTemplate before re-running.', 1;
    IF CHARINDEX(@OldSerial, @Body) = 0
        THROW 51000, 'Migration 0106: the SERIAL (1S) Code 39 field was not found verbatim (is 0103 applied?). Inspect Lots.LabelTemplate before re-running.', 1;

    SET @Body = REPLACE(@Body, @OldPart,   @NewPart);
    SET @Body = REPLACE(@Body, @OldLevel,  @NewLevel);
    SET @Body = REPLACE(@Body, @OldQty,    @NewQty);
    SET @Body = REPLACE(@Body, @OldSerial, @NewSerial);

    UPDATE Lots.LabelTemplate SET ZplBody = @Body WHERE Id = @Id;

    -- Prove it: all four new fields present, and no Code 39 left anywhere.
    DECLARE @Check NVARCHAR(MAX) = (SELECT ZplBody FROM Lots.LabelTemplate WHERE Id = @Id);
    IF CHARINDEX(@NewPart, @Check) = 0 OR CHARINDEX(@NewLevel, @Check) = 0
       OR CHARINDEX(@NewQty, @Check) = 0 OR CHARINDEX(@NewSerial, @Check) = 0
        THROW 51000, 'Migration 0106: one or more Code 128 fields did not land. Rolled back.', 1;
    IF CHARINDEX(N'^B3', @Check) > 0
        THROW 51000, 'Migration 0106: a Code 39 (^B3) field survives. Rolled back.', 1;

    PRINT 'Migration 0106: Container label patched -- four barcodes now Code 128 with P / 2P / Q / 1S data identifiers.';
END

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0106_container_label_code128_and_data_identifiers')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0106_container_label_code128_and_data_identifiers',
            N'Container shipping label: the four linear barcodes move from Code 39 to Code 128 (auto subset) and carry their data identifiers (P / 2P / Q / 1S) to match the AIM batch label; part-number barcode drops dashes via {PartNumberBarcode}. Apply with Lots.ufn_ShippingLabelZpl v1.5.');
GO
PRINT 'Migration 0106 (container_label_code128_and_data_identifiers) applied.';
GO
