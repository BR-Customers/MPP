-- ============================================================
-- Repeatable:  R__Parts_ufn_AimCustomerPartNumber.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1 (2026-08-13) -- strips the -AEP / -ISP variant suffix.
-- Description: Derives the AIM Customer Part from Parts.Item.PartNumber by
--              stripping dashes. Migration 0054 removed the stored
--              Parts.Item.AimCustomerPartNumber column -- live testing against
--              MPP's AIM server this week proved the value is derivable, not an
--              independent fact that must be sourced from AIM:
--
--                Value sent to AIM         Result
--                11200-6FB-A00              Blanket not found
--                112006FBA00                 Blanket not found
--                112006FB A000               posted, label created  <-
--
--              The legacy MES material name for that part is '11200-6FB -A000'.
--              Strip the dashes and the result is '112006FB A000' exactly -- the
--              value that worked. This is also precisely what the legacy Base2
--              code did (partName.Replace("-", "")) before writing its CSV row
--              (notes/2026-07-28_aim-interface-contract.md).
--
--              STRIP DASHES ONLY. DO NOT trim or collapse whitespace -- the
--              embedded space in '112006FB A000' is part of AIM's lookup key, not
--              formatting noise. Do not "simplify" this back to the raw
--              PartNumber, and do not add a TRIM/whitespace-collapse step; both
--              would reintroduce the exact failure mode that took a week to
--              diagnose.
--
--              NULL in -> NULL out (REPLACE(NULL, ...) is already NULL, but this
--              is documented behavior the caller can rely on, not an accident).
--
--              v1.1 -- THE -AEP / -ISP VARIANT SUFFIX.
--              MPP's part list gives ONE part number to TWO different parts in two
--              cases: 19320-6A0 -A510 is both the AEP and the ISP Thermo Case Auto
--              (baskets 5 and 6, packing 16x5 and 16x6), and 19410-6A0 -A000 is
--              both the AEP and ISP Water Passage (baskets 60 and 15, packing 1x60
--              and 12x15). UQ_Item_PartNumber permits one row each, so they are
--              stored suffixed -- 19320-6A0 -A510-AEP / -ISP.
--
--              That suffix is a BLUE RIDGE bookkeeping convention. It is NOT part
--              of the Honda part number and AIM has never seen it, so it is
--              stripped here, before the dashes go. Without this the function would
--              emit '193206A0 A510AEP' and AIM would answer "Blanket not found" --
--              the same class of failure the header table above records.
--
--              Stripped BEFORE dash removal on purpose: at that point the test is
--              an anchored compare against the literal '-AEP' / '-ISP', so it
--              cannot misfire. After dash removal the suffix is a bare 'AEP' with
--              no boundary left to anchor on, and any part number legitimately
--              ending in those three letters would be silently corrupted.
--
--              Verified safe against the loaded part list (2026-08-13): the only
--              Item.PartNumber values ending in -AEP/-ISP are those four variants.
--              Four items DO carry a Macola part number ending in -AEP (186-AEP,
--              630-AEP, 662-AEP, 142-AEP), but MacolaPartNumber is a separate
--              column and is never passed to this function.
--
--              If MPP ever supplies real distinct part numbers for these four,
--              delete the suffixes and this strip together -- it exists only to
--              serve them.
--
--              Known gap: AIM's Customer Part / Item Number Cross-Reference showed
--              one row this rule cannot reproduce -- 11300R70 A000 -> 11300R7-
--              A000 (a DASH appears in the AIM-side value where the item number
--              has a '0'). An irregular part like that will still need a manual
--              look before it ships; see notes/2026-07-28_aim-interface-contract.md.
-- ============================================================
CREATE OR ALTER FUNCTION Parts.ufn_AimCustomerPartNumber (@PartNumber NVARCHAR(50))
RETURNS NVARCHAR(50)
AS
BEGIN
    DECLARE @p NVARCHAR(50) = @PartNumber;

    -- Anchored on the dash, so it fires only on the variant convention. LEN() is
    -- safe here: LIKE '%-AEP' cannot match a value with trailing whitespace, so in
    -- this branch LEN() equals the true length.
    IF @p LIKE N'%-AEP' OR @p LIKE N'%-ISP'
        SET @p = LEFT(@p, LEN(@p) - 4);

    RETURN REPLACE(@p, N'-', N'');
END;
GO
