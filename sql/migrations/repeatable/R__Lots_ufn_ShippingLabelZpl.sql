-- ============================================================
-- Repeatable: R__Lots_ufn_ShippingLabelZpl.sql
-- Author:     Blue Ridge Automation
-- Version:    1.3
-- Description: Brief D (FAT-LBL-050) -- render the container shipping-label ZPL.
--   Resolves the ACTIVE Container Lots.LabelTemplate.ZplBody and substitutes the
--   {Placeholder} tokens from the container + its Item + the BOM version used to
--   build it + the composed serial. Pure/deterministic (no side effects) so both
--   Container_Complete and ShippingLabel_Reprint call it inside their own
--   transactions.
--
--   Token map:
--     {PartNumber}    <- Parts.Item.PartNumber (container's Item)
--     {Description}   <- Parts.Item.Description
--     {MfgLotNumber}  <- @AimShipperId (AIM minted serial)
--     {MfgDate}       <- Container.CompletedAt, UTC->Eastern, M/dd/yy
--     {DcPartLevel}   <- the BOM VersionNumber actually used to mint the container's
--                        trays (Lots.ContainerTray -> FinishedGoodLotId -> Lot.BomId
--                        -> Parts.Bom.VersionNumber), zero-padded to 2 digits ('00',
--                        '01', '02', ...; FORMAT does not truncate past 2 digits, so
--                        a 3-digit version like 100 still renders correctly). v1.1
--                        (2026-08-20): was Tools.ufn_ContainerOriginDieRankCode
--                        (genealogy die-rank trace) -- deliberately traces the BOM
--                        actually recorded on the tray's FG LOT at mint time, NOT
--                        whichever BOM version is currently active/published, so a
--                        later reprint still shows the version the container was
--                        actually built against.
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
    DECLARE @BomVersion INT = (
        SELECT TOP 1 b.VersionNumber
        FROM Lots.ContainerTray ct
        INNER JOIN Lots.Lot l  ON l.Id = ct.FinishedGoodLotId
        INNER JOIN Parts.Bom b ON b.Id = l.BomId
        WHERE ct.ContainerId = @ContainerId
        ORDER BY ct.TrayPosition DESC);
    DECLARE @DcPartLevel NVARCHAR(20)  = CASE WHEN @BomVersion IS NULL THEN N'' ELSE FORMAT(@BomVersion, N'00') END;
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
