-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_GetEligibility.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-20
-- Version:     1.0
-- Description: Super-lot piece 5 (final review). READ. Whether one LOT can be
--              returned to a vendor, and if not, why -- the LOT Detail "Vendor
--              return" tab shows the Mark form or the Reason from this, so the
--              rule is never re-derived in a binding.
--
--              A thin read over Lots.ufn_LotReturnableToVendor, the single
--              definition shared with Lots.VendorReturn_Mark (whose refusal text
--              is the same Reason), Quality.ControlledRunResult_Record and
--              Quality.ControlledRun_ListMemberOrigin.
--
--              FDS-11-011: no OUTPUT params; single result set. Empty set = LOT
--              not found.
-- Result set:  LotId, CanReturnToVendor BIT, Reason NVARCHAR(500) (NULL when returnable)
-- Change Log:
--   2026-10-20 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.VendorReturn_GetEligibility
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT rv.LotId, rv.CanReturnToVendor, rv.Reason
    FROM Lots.ufn_LotReturnableToVendor(@LotId) rv;
END;
GO
