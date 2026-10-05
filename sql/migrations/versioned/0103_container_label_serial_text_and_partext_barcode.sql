-- ============================================================
-- Migration:   0103_container_label_serial_text_and_partext_barcode.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-05
-- Description: Two corrections to the Container shipping label, found on the
--              FIRST real label printed at 6MA Cam Holder Line 1 during the
--              2026-10-05 onsite parallel run, by comparison against the legacy
--              label for the same part.
--
--   1. SERIAL SEPARATOR, TEXT ONLY.
--      The legacy label prints the human-readable serial as
--      '13218001-13933626'; ours printed '1321800113933626'. The separator is
--      for the person reading it. The Code 39 barcode underneath is what Honda
--      SCANS and must keep the unseparated payload -- so the template's single
--      {Serial} token is split into {SerialText} (dashed) and {SerialBarcode}
--      (not). Confirmed with Jacques onsite 2026-10-05: "dash in the text only,
--      barcode stays without it."
--
--      Lots.ufn_ShippingLabelZpl v1.2 supplies both, and still resolves a bare
--      {Serial} to the BARCODE form so a template row that misses this migration
--      cannot print a literal '{Serial}' on a Honda label.
--
--   2. PART NO. EXT (C) BARCODE REMOVED.
--      {PartNumberExt} is blank by design on every real MPP container label (see
--      ufn_ShippingLabelZpl's header). An empty ^B3 does NOT print nothing: Code
--      39 still emits its start/stop characters, which is the short stub barcode
--      visible under that caption on our label and absent from the legacy one.
--      The CAPTION and the (empty) text field are retained -- the field exists in
--      the layout, it simply has no value -- only the barcode command is dropped.
--
--   NOT ADDRESSED HERE, deliberately: the {DataMatrix} field is also substituted
--   with '' and prints the same kind of degenerate stub. Unlike PartNumberExt it
--   is NOT blank by design -- the legacy label carries a populated 2D symbol, and
--   what it encodes is a Honda specification we do not have in the repo. Left
--   printing a stub rather than removed, because the field is about to be given
--   real content; if that stalls, drop the ^BX line the same way this migration
--   drops the ^B3 one.
--
--   IDEMPOTENT + GUARDED. Each edit asserts it changed exactly the row it meant
--   to. A label template is a Honda traceability artifact; a REPLACE that
--   silently matched nothing would ship a label that looks fixed and is not.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
IF @ContainerTypeId IS NULL
    THROW 51000, 'Migration 0103: no Container LabelTypeCode -- schema is not where this migration expects.', 1;

DECLARE @Id BIGINT = (SELECT TOP 1 Id FROM Lots.LabelTemplate
                      WHERE LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL
                      ORDER BY Id);
IF @Id IS NULL
    THROW 51000, 'Migration 0103: no active Container LabelTemplate to patch.', 1;

DECLARE @Body NVARCHAR(MAX) = (SELECT ZplBody FROM Lots.LabelTemplate WHERE Id = @Id);

-- ---- 1a. human-readable serial -> {SerialText} ----
DECLARE @OldText NVARCHAR(200) = N'^A0R,72,72^FO140,200^FD{Serial}^FS';
DECLARE @NewText NVARCHAR(200) = N'^A0R,72,72^FO140,200^FD{SerialText}^FS';

-- ---- 1b. Code 39 serial -> {SerialBarcode} ----
DECLARE @OldBc NVARCHAR(200) = N'^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS';
DECLARE @NewBc NVARCHAR(200) = N'^A0R^FO50,60^BY3^B3,,95,N,^FD{SerialBarcode}^FS';

-- ---- 2. drop the PART NO. EXT (C) Code 39 ----
DECLARE @OldExt NVARCHAR(200) = N'^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS';

-- Already applied? (re-run safety -- the new tokens are present and the stub is gone.)
IF CHARINDEX(@NewText, @Body) > 0 AND CHARINDEX(@NewBc, @Body) > 0 AND CHARINDEX(@OldExt, @Body) = 0
BEGIN
    PRINT 'Migration 0103: Container label already patched -- no change.';
END
ELSE
BEGIN
    IF CHARINDEX(@OldText, @Body) = 0
        THROW 51000, 'Migration 0103: the human-readable {Serial} field was not found verbatim. The template has diverged -- inspect Lots.LabelTemplate before re-running.', 1;
    IF CHARINDEX(@OldBc, @Body) = 0
        THROW 51000, 'Migration 0103: the Code 39 {Serial} field was not found verbatim. The template has diverged -- inspect Lots.LabelTemplate before re-running.', 1;
    IF CHARINDEX(@OldExt, @Body) = 0
        THROW 51000, 'Migration 0103: the PART NO. EXT (C) barcode field was not found verbatim. The template has diverged -- inspect Lots.LabelTemplate before re-running.', 1;

    SET @Body = REPLACE(@Body, @OldText, @NewText);
    SET @Body = REPLACE(@Body, @OldBc,   @NewBc);
    -- Drop the barcode command only; the caption and the empty text field stay.
    SET @Body = REPLACE(@Body, @OldExt + NCHAR(13) + NCHAR(10), N'');
    SET @Body = REPLACE(@Body, @OldExt + NCHAR(10), N'');
    SET @Body = REPLACE(@Body, @OldExt, N'');

    UPDATE Lots.LabelTemplate SET ZplBody = @Body WHERE Id = @Id;

    -- Prove it: the old single token must be gone from BOTH serial fields, the
    -- two new ones present, and the stub barcode absent.
    DECLARE @Check NVARCHAR(MAX) = (SELECT ZplBody FROM Lots.LabelTemplate WHERE Id = @Id);
    IF CHARINDEX(@NewText, @Check) = 0 OR CHARINDEX(@NewBc, @Check) = 0
        THROW 51000, 'Migration 0103: serial tokens did not land. Rolled back.', 1;
    IF CHARINDEX(@OldExt, @Check) > 0
        THROW 51000, 'Migration 0103: PART NO. EXT barcode still present. Rolled back.', 1;
    IF CHARINDEX(N'{Serial}', @Check) > 0
        THROW 51000, 'Migration 0103: a bare {Serial} token survives. Rolled back.', 1;

    PRINT 'Migration 0103: Container label patched -- serial split into text/barcode, PART NO. EXT barcode removed.';
END

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0103_container_label_serial_text_and_partext_barcode')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0103_container_label_serial_text_and_partext_barcode',
            N'Container shipping label: {Serial} split into {SerialText} (dashed, human-readable) and {SerialBarcode} (unseparated, the payload Honda scans); PART NO. EXT (C) Code 39 removed because an empty ^B3 still prints start/stop bars. Apply with Lots.ufn_ShippingLabelZpl v1.2.');

COMMIT TRANSACTION;
GO
PRINT 'Migration 0103 (container_label_serial_text_and_partext_barcode) applied.';
GO
