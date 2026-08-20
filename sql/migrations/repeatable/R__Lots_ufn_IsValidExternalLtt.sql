-- ============================================================
-- Repeatable:  R__Lots_ufn_IsValidExternalLtt.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1 (2026-08-19)
-- Change Log:  2026-07-20 - 1.0 - Initial: exactly 9 numeric digits.
--              2026-08-19 - 1.1 - Backlog 5.1. MPP's pre-printed LTT stock is
--                                 EIGHT digits, not nine. The 9-digit-only rule
--                                 (taken from a verbal 2026-07-20 note, never
--                                 sourced to the FRS -- FRS 2.2.1 states no digit
--                                 count) rejects every real ticket at Die Cast.
--                                 The rule is now "8 OR 9 numeric digits".
--
--                                 Why 9 is still accepted rather than dropped:
--                                 Dev/Test and every SQL fixture already carry
--                                 9-digit LTTs (000000024, 303030301, ...) and
--                                 Lot.LotName is the LOT's permanent identity --
--                                 narrowing to 8-only would orphan that data for
--                                 no business gain. If MPP confirms 8 is the ONLY
--                                 legal length, tightening is a one-line edit
--                                 here plus a fixture sweep. See the report /
--                                 PROJECT_STATUS open question.
-- Description: External LTT format rule. LTTs are bulk pre-printed by an external
--              scheduler; the MES adopts the scanned value verbatim as
--              Lots.Lot.LotName. This function is the SINGLE format gate in the
--              system -- its only callers are Lots.Lot_Create (die-cast-origin
--              branch) and Lots.DieCastLot_Open. A check-digit/checksum is
--              expected but not yet confirmed (spec 2026-07-20 open item) -- the
--              checksum stub below returns valid, so the real rule drops in here
--              with no caller churn.
--
--              NOT to be confused with the AIM shipper serial, which is a
--              genuinely 9-digit zero-padded identifier confirmed against the
--              live AIM service (notes/2026-07-28_aim-interface-contract.md).
--              That format lives in BlueRidge.Lots.AimHttp and is unrelated.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_IsValidExternalLtt (@Ltt NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @Ok BIT = 0;
    -- 8 or 9 characters, each a digit 0-9. A LIKE built only from [0-9] classes is
    -- anchored at both ends, so each pattern matches iff the string is exactly that
    -- many digits.
    IF @Ltt LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
       OR @Ltt LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        SET @Ok = 1;
    -- CHECKSUM STUB: when the external LTT check-digit algorithm is confirmed, add the
    -- validation here (set @Ok = 0 on a checksum failure). Currently a no-op.
    RETURN @Ok;
END;
GO
