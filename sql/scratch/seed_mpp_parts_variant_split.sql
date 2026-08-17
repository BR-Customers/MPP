-- ============================================================
-- Script:      seed_mpp_parts_variant_split.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-13
-- Description: Splits the two part numbers that each cover TWO different parts.
--
--              MPP's workbook lists 19320-6A0 -A510 twice (Thermo Case Auto AEP,
--              basket 5; and ISP, basket 6) and 19410-6A0 -A000 twice (Water
--              Passage AEP, basket 60; and ISP, basket 15) -- different parts,
--              different Honda packing rules, one part number each.
--              UQ_Item_PartNumber permits one row, so only the AEP variant loaded.
--
--              Renames the loaded row to its -AEP name; seed_mpp_parts.sql then
--              inserts the -ISP sibling and its container config.
--
--              Each variant's "Parts Per Basket" equals the "Parts Per Tray" of
--              exactly one packaging row (AEP 5 -> 16x5 / ISP 6 -> 16x6;
--              AEP 60 -> 1x60 / ISP 15 -> 12x15), so the packing rule each variant
--              gets is determined by the data, not chosen.
--
--              *** The -AEP / -ISP suffix is a Blue Ridge convention, NOT an MPP
--              part number. It MUST be stripped before the value reaches AIM.
--              Parts.ufn_AimCustomerPartNumber today is only
--              REPLACE(@PartNumber, '-', ''), which would emit "193206A0 A510AEP"
--              -- not a valid Honda part number. That function is unchanged here
--              deliberately: it is the one piece with proven live-AIM evidence
--              behind it, so it is not touched without a decision. ***
--
--              Safe to rename: verified both rows carry zero LOTs, zero BOM
--              references and zero routes (they are off-site parts with no
--              eligibility). Idempotent. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @R TABLE (OldPn NVARCHAR(50), NewPn NVARCHAR(50));
INSERT INTO @R (OldPn, NewPn) VALUES
 (N'19320-6A0 -A510', N'19320-6A0 -A510-AEP'),
 (N'19410-6A0 -A000', N'19410-6A0 -A000-AEP');

-- Guard: refuse to rename anything that has grown a dependency since this was written.
IF EXISTS (
    SELECT 1 FROM @R r
    JOIN Parts.Item i ON i.PartNumber = r.OldPn
    WHERE EXISTS (SELECT 1 FROM Lots.Lot l          WHERE l.ItemId = i.Id)
       OR EXISTS (SELECT 1 FROM Parts.BomLine bl    WHERE bl.ChildItemId = i.Id)
       OR EXISTS (SELECT 1 FROM Parts.RouteTemplate rt WHERE rt.ItemId = i.Id))
BEGIN
    RAISERROR(N'variant_split: a target part now has LOTs/BOM/route refs - review before renaming.', 16, 1);
    RETURN;
END

UPDATE i SET i.PartNumber = r.NewPn, i.UpdatedAt = SYSUTCDATETIME()
FROM Parts.Item i
JOIN @R r ON r.OldPn = i.PartNumber
WHERE NOT EXISTS (SELECT 1 FROM Parts.Item x WHERE x.PartNumber = r.NewPn);
PRINT 'variant_split: renamed -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));
GO

PRINT 'variant_split: done. Now re-run seed_mpp_parts.sql to add the -ISP siblings.';
GO
