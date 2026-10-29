-- =============================================
-- Repeatable:  R__Oee_ufn_RejectChargeFamily.sql
-- Object:      Oee.ufn_RejectChargeFamily
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: Which area family a reject is CHARGED to, by its defect code's
--              Quality.ChargeToParty (OEE dashboard spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.4, decisions D11/D12 -- the same ownership rule as
--              Quality.Reject_GetPlantSummary):
--                DieCast, DieMaintenance  -> diecast
--                TrimShop                 -> trim
--                MachineShop              -> ma
--                MppNonSpecific, SupplierNonSpecific, or no party
--                                         -> @FoundFamily (where it was found)
--              @FoundFamily is the family of the location the reject was
--              recorded at (Oee.ufn_AreaFamily); NULL when that is unknown.
--              No row for an unknown defect code.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_RejectChargeFamily (@DefectCodeId BIGINT, @FoundFamily NVARCHAR(10))
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(CASE p.Code
                    WHEN N'DieCast'        THEN N'diecast'
                    WHEN N'DieMaintenance' THEN N'diecast'
                    WHEN N'TrimShop'       THEN N'trim'
                    WHEN N'MachineShop'    THEN N'ma'
                    ELSE @FoundFamily
                END AS NVARCHAR(10)) AS ChargeFamily
    FROM Quality.DefectCode dc
    LEFT JOIN Quality.ChargeToParty p ON p.Id = dc.ChargeToPartyId
    WHERE dc.Id = @DefectCodeId
);
GO
