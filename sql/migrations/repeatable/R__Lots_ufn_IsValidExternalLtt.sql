-- ============================================================
-- Repeatable:  R__Lots_ufn_IsValidExternalLtt.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0 (2026-07-20)
-- Description: External Die Cast LTT format rule. LTTs are bulk pre-printed by an
--              external scheduler; the MES adopts the scanned value verbatim as
--              Lots.Lot.LotName. This function is the format gate: exactly 9 numeric
--              digits. A check-digit/checksum is expected but not yet confirmed
--              (spec 2026-07-20 open item) -- the checksum stub below returns valid,
--              so the real rule drops in here with no caller churn.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_IsValidExternalLtt (@Ltt NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @Ok BIT = 0;
    -- Exactly 9 characters, each a digit 0-9 (LIKE with 9 [0-9] classes is anchored
    -- both ends -> matches iff the string is exactly 9 digits).
    IF @Ltt LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        SET @Ok = 1;
    -- CHECKSUM STUB: when the external LTT check-digit algorithm is confirmed, add the
    -- validation here (set @Ok = 0 on a checksum failure). Currently a no-op.
    RETURN @Ok;
END;
GO
