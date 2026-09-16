"""Generate migration 0087 from the three sheet tables.

Set-based and database-independent: the 105 printed lines go into a table
variable, get their ids resolved once, then one UPDATE (wording) and one
INSERT (whatever is absent). No row ids are baked in, nothing is deleted,
and re-running changes nothing.
"""
import json, sys

d = json.load(open(sys.argv[1]))
out = sys.argv[2]

sheet = []
for r in d["DC"]:     sheet.append(("DieCast", "DieCast", r["padded"], r["sheetDesc"]))
for r in d["TRIM"]:   sheet.append(("Trim", "TrimShop", r["padded"], r["sheetDesc"]))
for r in d["MA_DC"]:  sheet.append(("MachiningAssembly", "DieCast", r["padded"], r["sheetDesc"]))
for r in d["MA_MS"]:  sheet.append(("MachiningAssembly", "MachineShop", r["padded"], r["sheetDesc"]))

def q(s):
    return s.replace("'", "''")

H = """-- ============================================================
-- Migration:   0087_defectcode_area_scoped_codes.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-15
-- Description: Makes Quality.DefectCode hold every reject code printed on the
--              three shop-floor sheets, each under the area whose sheet prints
--              it, with the code exactly as printed.
--
--                DCFM-0485 v18  Die Cast              36 codes
--                TSFM-0085 v7   Trim Shop             36 codes
--                line sheet     Machining & Assembly  33 codes
--                                                    ----
--                                                     105 rows
--
--              NO CODE IS RENUMBERED. The numbers live in systems outside the
--              MES and are honoured exactly as printed.
--
--              The grouping is the FK that already exists:
--              OperationCategoryId. The only thing blocking this was
--              UQ_DefectCode_Code being GLOBAL -- those 105 rows carry just 86
--              distinct numbers, because 17 codes are printed on more than one
--              sheet, and 133 / 134 appear twice on the M&A sheet alone (once
--              charged to Die Cast, once to the Machine Shop). So the key
--              becomes (OperationCategoryId, ChargeToPartyId, Code), which is
--              unique across all 105.
--
--              Also strips the 'DC - ' description prefix from migration 0086.
--              That hit all 59 die-cast-CHARGED codes when the M&A sheet lists
--              17; attribution belongs in ChargeToPartyId, which this migration
--              sets per row, not in the label.
--
--              Set-based and id-free, so it behaves the same on Dev, ProdSim
--              and Prod. Nothing is deleted -- codes the database holds that no
--              sheet claims are left exactly as they are. Re-running is a
--              no-op.
--
-- Change Log:
--   2026-09-15 - 1.0 - Initial version
-- ============================================================

SET XACT_ABORT ON;

-- ---- 1. Undo 0086's blanket description prefix ----
UPDATE Quality.DefectCode
   SET Description = SUBSTRING(Description, 6, LEN(Description) - 5)
 WHERE Description LIKE N'DC - %';
GO

-- ---- 2. Re-key: a code is unique per (area, charge-to), not plant-wide ----
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DefectCode_Code')
    ALTER TABLE Quality.DefectCode DROP CONSTRAINT UQ_DefectCode_Code;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_DefectCode_Area_Charge_Code')
    CREATE UNIQUE INDEX UQ_DefectCode_Area_Charge_Code
        ON Quality.DefectCode (OperationCategoryId, ChargeToPartyId, Code);
GO

-- ---- 3. The three sheets, one row per printed line ----
DECLARE @Sheet TABLE (Area NVARCHAR(30), ChargeTo NVARCHAR(30),
                      Code NVARCHAR(20), Descr NVARCHAR(500));

INSERT INTO @Sheet (Area, ChargeTo, Code, Descr) VALUES
"""

F = """

DECLARE @Want TABLE (OperationCategoryId BIGINT, ChargeToPartyId BIGINT,
                     Code NVARCHAR(20), Descr NVARCHAR(500));

INSERT INTO @Want (OperationCategoryId, ChargeToPartyId, Code, Descr)
SELECT oc.Id, cp.Id, s.Code, s.Descr
  FROM @Sheet s
  JOIN Parts.OperationCategory oc ON oc.Code = s.Area
  JOIN Quality.ChargeToParty   cp ON cp.Code = s.ChargeTo;

IF (SELECT COUNT(*) FROM @Want) <> (SELECT COUNT(*) FROM @Sheet)
    RAISERROR(N'0087: an OperationCategory or ChargeToParty code did not resolve.', 16, 1);

-- 3a. Already filed correctly -- make the wording match the paper.
UPDATE dc SET Description = w.Descr
  FROM Quality.DefectCode dc
  JOIN @Want w ON w.OperationCategoryId = dc.OperationCategoryId
               AND w.ChargeToPartyId    = dc.ChargeToPartyId
               AND w.Code               = dc.Code
 WHERE dc.Description <> w.Descr;
PRINT '0087: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' description(s) matched to the sheet.';

-- 3b. Everything the sheet prints that the table does not hold for that area.
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, ChargeToPartyId, IsExcused)
SELECT w.Code, w.Descr, w.OperationCategoryId, w.ChargeToPartyId, 0
  FROM @Want w
 WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc
                    WHERE dc.OperationCategoryId = w.OperationCategoryId
                      AND dc.ChargeToPartyId     = w.ChargeToPartyId
                      AND dc.Code                = w.Code);
PRINT '0087: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' code(s) added.';
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0087_defectcode_area_scoped_codes')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0087_defectcode_area_scoped_codes',
            N'Quality.DefectCode carries all 105 codes printed on DCFM-0485 v18, TSFM-0085 v7 and the M&A line production sheet, one row per printed line, grouped by the existing OperationCategoryId FK. Global UQ_DefectCode_Code replaced by UQ_DefectCode_Area_Charge_Code on (OperationCategoryId, ChargeToPartyId, Code) -- 105 rows carry 86 distinct numbers. No code renumbered, nothing deleted. 0086 description prefix removed.');
GO
PRINT 'Migration 0087 (defectcode_area_scoped_codes) applied.';
"""

vals = ",\n".join("(N'%s', N'%s', N'%s', N'%s')" % (a, c, code, q(desc))
                  for a, c, code, desc in sheet) + ";"

open(out, "w", encoding="utf-8", newline="\n").write(H + vals + F)
print("sheet rows: %d  ->  %s" % (len(sheet), out))
