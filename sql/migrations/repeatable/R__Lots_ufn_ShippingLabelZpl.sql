-- ============================================================
-- Repeatable: R__Lots_ufn_ShippingLabelZpl.sql
-- Author:     Blue Ridge Automation
-- Version:    1.5
-- Description: Brief D (FAT-LBL-050) -- render the container shipping-label ZPL.
--   Resolves the ACTIVE Container Lots.LabelTemplate.ZplBody and substitutes the
--   {Placeholder} tokens from the container + its Item + the BOM version used to
--   build it + the composed serial. Pure/deterministic (no side effects) so both
--   Container_Complete and ShippingLabel_Reprint call it inside their own
--   transactions.
--
--   Token map:
--     {PartNumber}    <- Parts.Item.PartNumber (container's Item)
--     {PartNumberBarcode} <- v1.5 (2026-10-06): PartNumber with every '-' removed (space
--                        kept), e.g. '1223A-6MA -J000' -> '1223A6MA J000'. The form the
--                        AIM batch label's PART NO. barcode scans as, less its 'P'.
--                        DATA IDENTIFIERS (P / 2P / Q / 1S) ARE TEMPLATE LITERALS as of
--                        migration 0106 -- no token here carries one. Do not add a prefix
--                        to {SerialBarcode} or {DcPartLevel}: the template already does,
--                        and it would double.
--     {Description}   <- Parts.Item.Description
--     {MfgLotNumber}  <- @AimShipperId (AIM minted serial)
--     {MfgDate}       <- Container.CompletedAt, UTC->Eastern, M/dd/yy
--     {DcPartLevel}   <- v1.4 (2026-10-05): Parts.Item.DcPartLevel, ENTERED per part,
--                        zero-padded to two digits; NULL renders '00'.
--
--                        WAS the BOM version actually recorded on the tray's finished-good
--                        LOT. That was internally consistent but did not mean what Honda
--                        means by this field: onsite, 1223A-6MA -J000 printed '04' because
--                        four BOM revisions exist for it, while its true D/C part level is
--                        '00'. Two unrelated numbers that happened to share a format.
--
--                        There is deliberately NO fallback to the BOM version when the
--                        column is NULL. A fallback would put two different numbers in one
--                        field depending on whether anyone had edited that part yet, which
--                        is harder to audit than a consistent default. The cost is stated
--                        in migration 0104: a part whose real level is not 00 prints 00
--                        until its row is set.
--     {Quantity}      <- SUM(closed tray PartsClosedCount)
--     {SerialBarcode} <- '13218001' (fixed MPP->Honda supplier code) + last 8 of the AIM
--                        serial, UNSEPARATED. This is what Honda scans, so it carries NO
--                        dash -- adding one would change the scanned payload.
--     {SerialText}    <- the same value with a '-' between the supplier code and the AIM 8,
--                        for the human-readable line only (matches the legacy label).
--                        v1.2 (2026-10-05): split from a single {Serial} token after the
--                        first real container label printed without the separator. The
--                        two MUST stay different: text is read by people, barcode by
--                        Honda. {Serial} is still substituted (to the barcode form) so an
--                        un-migrated template row cannot print a literal '{Serial}'.
--     {Coo}           <- 'USA'
--     {DataMatrix}    <- v1.3 (2026-10-05). The 2D payload, reconstructed from a scan of
--                        the legacy label for 1223A-6MA -J000 taken onsite:
--                            13933626 P1223A6MA J000 96
--                        i.e. <last 8 of the AIM shipper> + ' P' + <PartNumber with
--                        every '-' removed> + ' ' + <quantity>. The 'P' is the AIAG
--                        data identifier for part number, matching the label's own
--                        'PART NO. (P)' caption.
--
--                        SEPARATORS ARE ASSUMED TO BE LITERAL SPACES, and that is the
--                        one soft spot. The reference came from a scan pasted into a
--                        text editor, which renders an ASCII GS (29) / RS (30) as
--                        nothing or as whitespace -- so a space here is indistinguishable
--                        from a control character there. If Honda's scanner rejects the
--                        payload, re-scan into something that shows hex and compare;
--                        the fix would be to swap these two spaces, nothing more.
--
--                        Takes the last 8 of the AIM shipper rather than stripping a
--                        leading zero: both produce '13933626' from '013933626', so the
--                        single reference sample cannot tell them apart, and RIGHT(,8) is
--                        the rule the serial already uses two lines below. Consistency
--                        was the tie-break, not evidence.
--     {PartNumberExt} / {Auditor} <- blank by design (empty on every real MPP container
--                        label; captions retained, and 0103 removed the empty-^B3 stub
--                        barcode that PartNumberExt was still emitting)
--
--   Unresolved-source tokens render as '' (label still prints). ASCII-only body.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_ShippingLabelZpl (@ContainerId BIGINT, @AimShipperId NVARCHAR(50))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
    DECLARE @Zpl NVARCHAR(MAX) =
        (SELECT TOP 1 ZplBody FROM Lots.LabelTemplate
         WHERE LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL);
    IF @Zpl IS NULL
        RETURN N'';

    DECLARE @ItemId BIGINT, @CompletedAt DATETIME2(3);
    SELECT @ItemId = ItemId, @CompletedAt = CompletedAt FROM Lots.Container WHERE Id = @ContainerId;

    DECLARE @PartNumber  NVARCHAR(50)  = ISNULL((SELECT PartNumber  FROM Parts.Item WHERE Id = @ItemId), N'');
    DECLARE @Description  NVARCHAR(500) = ISNULL((SELECT Description FROM Parts.Item WHERE Id = @ItemId), N'');
    DECLARE @Qty         INT           = ISNULL((SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray
                                                 WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL), 0);
    -- D/C PART LEVEL (2P): an ENTERED value on the part, zero-padded to two
    -- digits. NULL renders '00' -- see the header for why there is no fallback
    -- to the BOM version any more.
    DECLARE @DcPartLevel NVARCHAR(20) =
        FORMAT(ISNULL((SELECT DcPartLevel FROM Parts.Item WHERE Id = @ItemId), 0), N'00');
    DECLARE @Aim         NVARCHAR(50)  = ISNULL(@AimShipperId, N'');
    -- WIDTH IS LOAD-BEARING. '13218001' + 8 is exactly 16 chars, so the old
    -- NVARCHAR(16) fit it precisely -- and a dashed 17-char value assigned to it
    -- would have been TRUNCATED SILENTLY (T-SQL does not error on variable
    -- assignment), dropping the last digit of every Honda serial with nothing in
    -- any log. Declared wide deliberately; do not tighten it back.
    DECLARE @SerialBarcode NVARCHAR(32) = N'13218001' + RIGHT(@Aim, 8);
    DECLARE @SerialText    NVARCHAR(32) = N'13218001-' + RIGHT(@Aim, 8);
    -- See the header for the shape and for why the separators are spaces.
    DECLARE @DataMatrix  NVARCHAR(400) =
        RIGHT(@Aim, 8) + N' P' + REPLACE(@PartNumber, N'-', N'') + N' ' + CAST(@Qty AS NVARCHAR(20));
    DECLARE @MfgDate     NVARCHAR(20)  =
        CASE WHEN @CompletedAt IS NULL THEN N''
             ELSE FORMAT(CAST(@CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), N'M/dd/yy') END;

    SET @Zpl = REPLACE(@Zpl, N'{PartNumberBarcode}', REPLACE(@PartNumber, N'-', N''));
    SET @Zpl = REPLACE(@Zpl, N'{PartNumber}',    @PartNumber);
    SET @Zpl = REPLACE(@Zpl, N'{Description}',   @Description);
    SET @Zpl = REPLACE(@Zpl, N'{MfgLotNumber}',  @Aim);
    SET @Zpl = REPLACE(@Zpl, N'{MfgDate}',       @MfgDate);
    SET @Zpl = REPLACE(@Zpl, N'{DcPartLevel}',   @DcPartLevel);
    SET @Zpl = REPLACE(@Zpl, N'{Quantity}',      CAST(@Qty AS NVARCHAR(20)));
    SET @Zpl = REPLACE(@Zpl, N'{SerialText}',    @SerialText);
    SET @Zpl = REPLACE(@Zpl, N'{SerialBarcode}', @SerialBarcode);
    -- Fallback for a template row that still carries the pre-v1.2 single token:
    -- resolve it to the BARCODE form, which is the safe side of the split (a
    -- scanned payload that matches Honda, and a human line missing a dash).
    SET @Zpl = REPLACE(@Zpl, N'{Serial}',        @SerialBarcode);
    SET @Zpl = REPLACE(@Zpl, N'{Coo}',           N'USA');
    -- blank-by-design fields (captions retained; DataMatrix is populated as of v1.3)
    SET @Zpl = REPLACE(@Zpl, N'{PartNumberExt}', N'');
    SET @Zpl = REPLACE(@Zpl, N'{DataMatrix}',    @DataMatrix);
    SET @Zpl = REPLACE(@Zpl, N'{Auditor}',       N'');

    RETURN @Zpl;
END;
GO
