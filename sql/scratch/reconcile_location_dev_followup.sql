-- ============================================================
-- Script:      reconcile_location_dev_followup.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-13
-- Description: Two gaps left by sql/scripts/reconcile_location_dev.sql, found
--              when reconciling this Dev database on 2026-08-13.
--
--              (1) RESTORE THE INSPECTION LTT PRINTER.
--                  The reconcile retires EVERY existing printer to __OLD__ and
--                  re-creates them only for MOUT / AOUT / COMBINED / ASER
--                  terminals (gen_locations_mpp.js `printsFor`). INSPECT is not in
--                  that set, so INSP-SORT-T1 and 66B - Ins came out with no printer
--                  at all -- but the pass-through parts screen receives a vendor box
--                  as a Received-origin LOT and PRINTS AN LTT at that terminal
--                  (spec 2026-08-06). With no printer child, Terminal_GetPrinter
--                  resolves nothing and the print silently fails.
--                  This un-retires the printer that was already there.
--
--                  The durable fix belongs in gen_locations_mpp.js -- `printsFor`
--                  should include INSPECT -- but that regenerates
--                  011_seed_locations_mpp_plant.sql and shifts the P-NNN printer
--                  numbering, which several tests assert on. Left as a flagged
--                  decision rather than changed unilaterally.
--
--              (2) DEPRECATE THE 7 TERMINALS SITE HAS RETIRED.
--                  reconcile_location_dev.sql only ADDS and RENAMES; it never
--                  deprecates. These 7 carry Deprecated=1 in _site_locations.tsv
--                  (the authoritative onsite map) and gen_locations_mpp.js skips
--                  them, so they are absent from the seed but still live here.
--
--                  This also matters for the seeded part routes: the SubAssembly
--                  synthesis in seed_mpp_parts.sql treats MA1-FPRPY / MA1-5GOR /
--                  MA1-5GOF as having NO active Machining OUT (correct per Site),
--                  so leaving live MOUT terminals on those lines contradicts the
--                  routes now loaded.
--
--              Idempotent. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---- (1) restore the inspection LTT printer ----
UPDATE Location.Location
SET Code = N'INSP-SORT-T1-P1', DeprecatedAt = NULL
WHERE Code = N'__OLD__INSP-SORT-T1-P1'
  AND NOT EXISTS (SELECT 1 FROM Location.Location x WHERE x.Code = N'INSP-SORT-T1-P1');
PRINT 'followup: inspection printer restored -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- Re-parent defensively: the reconcile renamed terminals around it.
UPDATE c SET c.ParentLocationId = p.Id
FROM Location.Location c, Location.Location p
WHERE c.Code = N'INSP-SORT-T1-P1' AND p.Code = N'INSP-SORT-T1'
  AND c.ParentLocationId <> p.Id;
PRINT 'followup: printer re-parented        -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- ---- (2) deprecate the terminals Site has retired ----
DECLARE @Retire TABLE (Code NVARCHAR(50));
INSERT INTO @Retire (Code) VALUES
 (N'MA1-6MD-MIN'),        -- Site Deprecated=1
 (N'MA1-FPRPY-MOUT'),     -- Site Deprecated=1
 (N'MA1-5GOR-MOUT'),      -- Site Deprecated=1
 (N'MA1-5GOF-MOUT'),      -- Site Deprecated=1
 (N'MA2-RPYCAM2-AOUT2'),  -- Site Deprecated=1
 (N'MA2-RPYCAM2-AOUT3'),  -- Site Deprecated=1
 (N'MA2-RPYCAM1-AOUT2');  -- renamed from Site MA2-RPYCAM1-AOUT3, Deprecated=1

-- Guard: never retire a location that currently holds a LOT.
IF EXISTS (SELECT 1 FROM Lots.Lot lot JOIN Location.Location l ON l.Id = lot.CurrentLocationId
           JOIN @Retire r ON r.Code = l.Code)
BEGIN
    RAISERROR(N'followup: a terminal slated for retirement currently holds a LOT - review first.', 16, 1);
    RETURN;
END

UPDATE l SET l.DeprecatedAt = SYSUTCDATETIME()
FROM Location.Location l JOIN @Retire r ON r.Code = l.Code
WHERE l.DeprecatedAt IS NULL;
PRINT 'followup: Site-retired terminals deprecated -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- their printer children go too
UPDATE c SET c.DeprecatedAt = SYSUTCDATETIME()
FROM Location.Location c JOIN Location.Location p ON p.Id = c.ParentLocationId
JOIN @Retire r ON r.Code = p.Code
WHERE c.DeprecatedAt IS NULL;
PRINT 'followup: their printers deprecated         -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));
GO

PRINT 'followup: done.';
GO
