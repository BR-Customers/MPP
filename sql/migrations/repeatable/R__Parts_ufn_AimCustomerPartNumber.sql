-- ============================================================
-- Repeatable:  R__Parts_ufn_AimCustomerPartNumber.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0 (2026-08-04)
-- Description: Derives the AIM Customer Part from Parts.Item.PartNumber by
--              stripping dashes. Migration 0051 removed the stored
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
    RETURN REPLACE(@PartNumber, N'-', N'');
END;
GO
